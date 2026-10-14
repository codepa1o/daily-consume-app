import { AbortableTask, request, streamRequest } from '../../services/api';
import { authorizePrivacy } from '../../services/privacy';

type Conversation = { id: number; title: string; message_count: number; last_question: string; updated_at: string };
type Message = { id: number; role: 'user' | 'assistant'; content: string; status: string; error_message: string; metadata: { sources?: Array<{ title?: string; url?: string }> } };
type Attachment = { name: string; content_base64: string };
type InputEvent = { detail: { value: string } };
type TapEvent = { currentTarget: { dataset: Record<string, string> } };
let activeStream: AbortableTask | null = null;

Page({
  data: {
    conversations: [] as Conversation[], activeId: 0, title: '', messages: [] as Message[],
    question: '', useKnowledge: false, attachment: null as Attachment | null,
    streaming: false, stopping: false, loading: false, error: '', status: '',
    listOpen: false, renameOpen: false, renameTitle: '',
  },

  onShow() { void this.loadConversations(); },
  onUnload() { activeStream?.abort(); activeStream = null; },
  async loadConversations() {
    this.setData({ loading: true, error: '' });
    try {
      const conversations = await request<Conversation[]>('GET', 'chatbot/conversations');
      this.setData({ conversations, loading: false });
      if (this.data.activeId) await this.openConversationById(this.data.activeId);
      else if (conversations.length) await this.openConversationById(conversations[0].id);
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '加载对话失败' }); }
  },
  async openConversationById(id: number) {
    this.setData({ loading: true, error: '' });
    try {
      const result = await request<{ conversation: Conversation; messages: Message[] }>('GET', `chatbot/conversations/${id}`);
      this.setData({ activeId: id, title: result.conversation.title, messages: result.messages, loading: false, listOpen: false });
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '读取对话失败' }); }
  },
  openConversation(event: TapEvent) { void this.openConversationById(Number(event.currentTarget.dataset.id)); },
  async newConversation() {
    try {
      const conversation = await request<Conversation>('POST', 'chatbot/conversations', { title: '新对话' });
      this.setData({ activeId: conversation.id, title: conversation.title, messages: [], error: '', listOpen: false });
      await this.loadConversations();
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '新建对话失败' }); }
  },
  onQuestion(event: InputEvent) { this.setData({ question: event.detail.value }); },
  onKnowledge(event: InputEvent) { this.setData({ useKnowledge: Boolean(event.detail.value) }); },
  toggleList() { this.setData({ listOpen: !this.data.listOpen }); },
  onRenameInput(event: InputEvent) { this.setData({ renameTitle: event.detail.value }); },
  startRename() { this.setData({ renameTitle: this.data.title, renameOpen: true }); },
  closeRename() { this.setData({ renameOpen: false }); },
  async renameConversation() {
    const title = this.data.renameTitle.trim();
    if (!title || title.length > 80) { wx.showToast({ title: '标题需为 1–80 个字', icon: 'none' }); return; }
    try {
      await request('PUT', `chatbot/conversations/${this.data.activeId}`, { title });
      this.setData({ title, renameOpen: false });
      await this.loadConversations();
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '重命名失败' }); }
  },
  deleteConversation() {
    wx.showModal({ title: '删除当前对话？', content: '对话和消息都会被删除。', success: async (result) => {
      if (!result.confirm) return;
      try {
        await request('DELETE', `chatbot/conversations/${this.data.activeId}`);
        this.setData({ activeId: 0, title: '', messages: [] });
        await this.loadConversations();
      } catch (error) { this.setData({ error: error instanceof Error ? error.message : '删除失败' }); }
    } });
  },
  async chooseAttachment() {
    try { await authorizePrivacy(); }
    catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '无法使用附件', icon: 'none' }); return; }
    wx.chooseMessageFile({ count: 1, type: 'file', extension: ['txt', 'md', 'markdown', 'pdf'], success: (result) => {
      const file = result.tempFiles[0];
      if (!file) return;
      if (file.size > 10 * 1024 * 1024) { wx.showToast({ title: '附件不能超过 10 MB', icon: 'none' }); return; }
      wx.getFileSystemManager().readFile({ filePath: file.path, encoding: 'base64', success: (read) => {
        this.setData({ attachment: { name: file.name, content_base64: String(read.data) } });
      }, fail: () => wx.showToast({ title: '无法读取附件', icon: 'none' }) });
    } });
  },
  removeAttachment() { this.setData({ attachment: null }); },
  async send() {
    const question = this.data.question.trim();
    if (!question || this.data.streaming) return;
    let conversationId = this.data.activeId;
    try {
      if (!conversationId) {
        const created = await request<Conversation>('POST', 'chatbot/conversations', { title: question.slice(0, 40) });
        conversationId = created.id;
        this.setData({ activeId: conversationId, title: created.title });
      }
      const userMessage: Message = { id: Date.now(), role: 'user', content: question, status: 'complete', error_message: '', metadata: {} };
      const assistantMessage: Message = { id: Date.now() + 1, role: 'assistant', content: '', status: 'streaming', error_message: '', metadata: {} };
      this.setData({ messages: [...this.data.messages, userMessage, assistantMessage], question: '', streaming: true, stopping: false, error: '', status: '正在准备对话…' });
      await streamRequest(`chatbot/conversations/${conversationId}/messages/stream`, {
        question,
        use_knowledge: this.data.useKnowledge,
        attachments: this.data.attachment ? [this.data.attachment] : [],
      }, (name, payload) => {
        if (name === 'delta') {
          const messages = this.data.messages.slice();
          const last = messages[messages.length - 1];
          messages[messages.length - 1] = { ...last, content: last.content + String(payload.content ?? '') };
          this.setData({ messages });
        } else if (name === 'status') {
          this.setData({ status: String(payload.message ?? '正在生成回复…') });
        } else if (name === 'tool_start') {
          this.setData({ status: `正在调用工具：${String(payload.display_name ?? payload.name ?? '')}` });
        } else if (name === 'done') {
          const messages = this.data.messages.slice();
          const last = messages[messages.length - 1];
          messages[messages.length - 1] = { ...last, id: Number(payload.id ?? last.id), content: String(payload.content ?? last.content), status: 'complete', metadata: payload.metadata as Message['metadata'] ?? {} };
          this.setData({ messages, status: '完成' });
        } else if (name === 'error') {
          const message = String(payload.message ?? '回复失败');
          const messages = this.data.messages.slice();
          const last = messages[messages.length - 1];
          messages[messages.length - 1] = { ...last, status: 'failed', error_message: message };
          this.setData({ messages, status: message });
        }
      }, (task) => { activeStream = task; });
      activeStream = null;
      this.setData({ streaming: false, attachment: null });
      await this.loadConversations();
    } catch (error) {
      if (this.data.stopping) {
        this.setData({ streaming: false, stopping: false, status: '已停止生成' });
        activeStream = null;
        if (conversationId) await this.openConversationById(conversationId);
      } else {
        this.setData({ streaming: false, error: error instanceof Error ? error.message : '发送失败，请重试', status: '' });
        if (conversationId) await this.openConversationById(conversationId);
      }
    } finally { activeStream = null; }
  },
  stopGeneration() {
    if (!this.data.streaming || !activeStream) return;
    this.setData({ stopping: true, status: '正在停止生成…' });
    activeStream.abort();
  },
  retry() { void this.loadConversations(); },
});
