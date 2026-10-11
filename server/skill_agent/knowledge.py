"""知识库文档解析、切片、向量索引和账号内检索。"""
import io
import json
import math
import os
import re

from psycopg.types.json import Jsonb

from .engine import SkillAgentError, embedding


MAX_UPLOAD_BYTES = 10 * 1024 * 1024
SUPPORTED_TYPES = {'.md', '.markdown', '.txt', '.pdf'}


def parse_document(filename: str, content: bytes) -> tuple[str, list[tuple[int, str]]]:
    suffix = os.path.splitext(filename)[1].lower()
    if suffix not in SUPPORTED_TYPES:
        raise SkillAgentError('只支持 Markdown、TXT 或 PDF 文件。')
    if not content:
        raise SkillAgentError('上传文件为空。')
    if len(content) > MAX_UPLOAD_BYTES:
        raise SkillAgentError('文件不能超过 10 MB。')
    if suffix == '.pdf':
        try:
            from pypdf import PdfReader
            pages = PdfReader(io.BytesIO(content)).pages
            sections = [(index, clean_text(page.extract_text() or ''))
                        for index, page in enumerate(pages, 1)]
        except Exception as error:
            raise SkillAgentError('PDF 解析失败，请确认文件未损坏且包含可复制文本。') from error
        sections = [(page, text) for page, text in sections if text]
    else:
        try:
            text = content.decode('utf-8-sig')
        except UnicodeDecodeError:
            raise SkillAgentError('文本文件必须使用 UTF-8 编码。') from None
        sections = [(0, clean_text(text))]
    if not sections:
        raise SkillAgentError('文件没有解析出可索引的正文内容。')
    return suffix.lstrip('.'), sections


def clean_text(value: str) -> str:
    value = value.replace('\r\n', '\n').replace('\r', '\n')
    value = re.sub(r'[ \t]+', ' ', value)
    return re.sub(r'\n{3,}', '\n\n', value).strip()


def split_chunks(sections: list[tuple[int, str]]) -> list[dict]:
    try:
        chunk_size = min(2000, max(200, int(os.getenv('RAG_CHUNK_SIZE', '800'))))
        overlap = min(chunk_size // 2, max(0, int(os.getenv('RAG_CHUNK_OVERLAP', '120'))))
    except ValueError:
        chunk_size, overlap = 800, 120
    chunks = []
    for page, text in sections:
        blocks = [item.strip() for item in re.split(r'\n\s*\n+', text) if item.strip()]
        current = ''
        page_chunks = []
        for block in blocks:
            if len(block) > chunk_size:
                if current:
                    page_chunks.append(current)
                    current = ''
                start = 0
                while start < len(block):
                    page_chunks.append(block[start:start + chunk_size].strip())
                    if start + chunk_size >= len(block):
                        break
                    start += chunk_size - overlap
                continue
            candidate = f'{current}\n\n{block}'.strip() if current else block
            if len(candidate) <= chunk_size:
                current = candidate
            else:
                page_chunks.append(current)
                prefix = page_chunks[-1][-overlap:].strip() if overlap else ''
                current = f'{prefix}\n\n{block}'.strip()
        if current:
            page_chunks.append(current)
        chunks.extend({'chunk_index': len(chunks) + index, 'page_number': page,
                       'content': text} for index, text in enumerate(page_chunks) if text)
    if not chunks:
        raise SkillAgentError('文件没有解析出可索引的正文内容。')
    return chunks


def index_document(connect, user_id: int, document_id: int) -> None:
    with connect() as db:
        document = db.execute('''SELECT id,filename,file_type,content FROM skill_agent_documents
            WHERE id=%s AND user_id=%s''', (document_id, user_id)).fetchone()
        if not document:
            raise SkillAgentError('资料不存在或已被删除。')
        db.execute('''UPDATE skill_agent_documents SET status='indexing',error_message='',
            chunk_count=0,updated_at=now() WHERE id=%s AND user_id=%s''', (document_id, user_id))
        db.execute('DELETE FROM skill_agent_chunks WHERE document_id=%s AND user_id=%s',
                   (document_id, user_id))
    try:
        _, sections = parse_document(document['filename'], bytes(document['content']))
        chunks = split_chunks(sections)
        indexed = []
        for offset in range(0, len(chunks), 10):
            batch = chunks[offset:offset + 10]
            vectors = embedding([item['content'] for item in batch])
            indexed.extend((item, vector) for item, vector in zip(batch, vectors))
        if len(indexed) != len(chunks):
            raise SkillAgentError('资料切片向量化数量不完整。')
        with connect() as db:
            db.executemany('''INSERT INTO skill_agent_chunks
                (document_id,user_id,chunk_index,page_number,content,embedding,embedding_dim)
                VALUES (%s,%s,%s,%s,%s,%s,%s)''', [
                (document_id, user_id, item['chunk_index'], item['page_number'], item['content'],
                 Jsonb(vector), len(vector)) for item, vector in indexed
            ])
            db.execute('''UPDATE skill_agent_documents SET status='ready',error_message='',
                chunk_count=%s,updated_at=now() WHERE id=%s AND user_id=%s''',
                (len(indexed), document_id, user_id))
    except Exception as error:
        message = str(error)[:1000] or '资料索引失败。'
        with connect() as db:
            db.execute('''UPDATE skill_agent_documents SET status='failed',error_message=%s,
                updated_at=now() WHERE id=%s AND user_id=%s''', (message, document_id, user_id))
        raise


def cosine_similarity(left: list[float], right: list[float]) -> float:
    if not left or len(left) != len(right):
        return 0.0
    dot = sum(a * b for a, b in zip(left, right))
    norm_left = math.sqrt(sum(value * value for value in left))
    norm_right = math.sqrt(sum(value * value for value in right))
    return dot / (norm_left * norm_right) if norm_left and norm_right else 0.0


def retrieve(connect, user_id: int, query: str) -> tuple[list[dict], str]:
    if os.getenv('RAG_ENABLED', 'true').strip().lower() in {'0', 'false', 'no', 'off'}:
        return [], '本地资料库检索已关闭。'
    with connect() as db:
        rows = db.execute('''SELECT c.document_id,d.filename,c.chunk_index,c.page_number,
            c.content,c.embedding FROM skill_agent_chunks c
            JOIN skill_agent_documents d ON d.id=c.document_id AND d.user_id=c.user_id
            WHERE c.user_id=%s AND d.status='ready' ''', (user_id,)).fetchall()
    if not rows:
        return [], ''
    try:
        vector = embedding([query])[0]
        threshold = min(1.0, max(-1.0, float(os.getenv('RAG_MIN_SCORE', '0.2'))))
        top_k = min(10, max(1, int(os.getenv('RAG_TOP_K', '5'))))
    except (SkillAgentError, ValueError):
        return [], '知识库向量服务暂不可用。'
    scored = []
    for row in rows:
        saved = row['embedding']
        if isinstance(saved, str):
            try:
                saved = json.loads(saved)
            except ValueError:
                continue
        score = cosine_similarity(vector, saved)
        if score >= threshold:
            scored.append({**row, 'score': score})
    scored.sort(key=lambda item: item['score'], reverse=True)
    return scored[:top_k], ''


def rag_context(results: list[dict], error: str = '') -> str:
    if not results:
        return f'【本地资料库状态】{error}' if error else ''
    lines = ['【本地资料检索结果】', '优先依据以下资料回答，资料不足时说明需要进一步核验。']
    for index, item in enumerate(results, 1):
        page = f" 第 {item['page_number']} 页" if item['page_number'] else ''
        lines.extend((f"[L{index}] {item['filename']}{page}（相似度 {item['score']:.3f}）",
                      item['content']))
    return '\n'.join(lines)


def rag_sources(results: list[dict], error: str = '') -> list[dict]:
    if not results and error:
        return [{'filename': '', 'page_number': 0, 'chunk_index': 0,
                 'score': 0, 'content': error}]
    return [{'filename': item['filename'], 'page_number': item['page_number'],
             'chunk_index': item['chunk_index'], 'score': round(item['score'], 4),
             'content': item['content']} for item in results]
