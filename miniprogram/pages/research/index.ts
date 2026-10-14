import { getAccount, request, requestBinary } from '../../services/api';
import { authorizePrivacy } from '../../services/privacy';

type Source = 'arxiv' | 'openreview' | 'acl_anthology' | 'biorxiv' | 'medrxiv' | 'pmlr' | 'pmc_oa';
type Paper = { id: string; source: Source; title: string; authors: string[]; authorLine?: string; year?: number; venue?: string; abstract?: string; article_url?: string; filename: string; record: Record<string, unknown> };
type SavedPaper = { title: string; path: string; savedAt: string };
type Event = { detail: { value: string | number | boolean }; currentTarget: { dataset: Record<string, string> } };
const sources: Array<{ id: Source; label: string }> = [
  { id: 'arxiv', label: 'arXiv' }, { id: 'openreview', label: 'OpenReview' }, { id: 'acl_anthology', label: 'ACL Anthology' },
  { id: 'biorxiv', label: 'bioRxiv' }, { id: 'medrxiv', label: 'medRxiv' }, { id: 'pmlr', label: 'PMLR' }, { id: 'pmc_oa', label: 'PMC OA' },
];

Page({
  data: {
    sources: sources.map((source) => ({ ...source, selected: source.id === 'arxiv' })), selectedSources: ['arxiv'] as Source[], query: '', venueId: '', limit: 10, limits: [5, 10, 15, 20, 25, 30], limitIndex: 1,
    results: [] as Paper[], sourceErrors: [] as Array<{ source: string; message: string }>, saved: [] as SavedPaper[],
    loading: false, downloading: '', error: '',
  },
  onShow() { this.loadSaved(); },
  storageKey() { return `daily_consume_research_${getAccount()?.id ?? 0}`; },
  loadSaved() { this.setData({ saved: wx.getStorageSync<SavedPaper[]>(this.storageKey()) || [] }); },
  onQuery(event: Event) { this.setData({ query: String(event.detail.value) }); },
  onVenue(event: Event) { this.setData({ venueId: String(event.detail.value) }); },
  onLimit(event: Event) { const limitIndex = Number(event.detail.value); this.setData({ limitIndex, limit: this.data.limits[limitIndex] }); },
  toggleSource(event: Event) {
    const source = String(event.currentTarget.dataset.source) as Source;
    const selectedSources = this.data.selectedSources.includes(source)
      ? this.data.selectedSources.filter((item) => item !== source)
      : [...this.data.selectedSources, source];
    this.setData({ selectedSources, sources: sources.map((item) => ({ ...item, selected: selectedSources.includes(item.id) })) });
  },
  async search() {
    if (!this.data.query.trim()) { wx.showToast({ title: '请输入论文关键词或标题', icon: 'none' }); return; }
    if (!this.data.selectedSources.length) { wx.showToast({ title: '至少选择一个来源', icon: 'none' }); return; }
    this.setData({ loading: true, error: '', results: [], sourceErrors: [] });
    try {
      const response = await request<{ results: Paper[]; source_errors: Array<{ source: string; message: string }> }>('POST', 'research/papers/search', {
        query: this.data.query.trim(), sources: this.data.selectedSources, limit: this.data.limit,
        ...(this.data.venueId.trim() ? { venue_id: this.data.venueId.trim() } : {}),
      });
      this.setData({ results: response.results.map((paper) => ({ ...paper, authorLine: paper.authors.join('、') })), sourceErrors: response.source_errors, loading: false });
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '搜索失败，请稍后重试' }); }
  },
  async download(event: Event) {
    const paper = this.data.results[Number(event.currentTarget.dataset.index)];
    this.setData({ downloading: paper.id, error: '' });
    try {
      const bytes = await requestBinary('research/papers/download', { source: paper.source, paper: paper.record });
      const name = (paper.filename || `${paper.title}.pdf`).replace(/[\\/:*?"<>|]/g, '_').slice(0, 120);
      const path = `${wx.env.USER_DATA_PATH}/${Date.now()}-${name}`;
      await new Promise<void>((resolve, reject) => wx.getFileSystemManager().writeFile({ filePath: path, data: bytes, success: () => resolve(), fail: () => reject(new Error('无法保存 PDF 文件')) }));
      const saved = [{ title: paper.title, path, savedAt: new Date().toISOString() }, ...this.data.saved];
      wx.setStorageSync(this.storageKey(), saved);
      this.setData({ saved, downloading: '' });
      this.openFile(path);
    } catch (error) { this.setData({ downloading: '', error: error instanceof Error ? error.message : '下载失败，请重试' }); }
  },
  async copyArticleUrl(event: Event) {
    const url = this.data.results[Number(event.currentTarget.dataset.index)].article_url;
    if (!url) return;
    try { await authorizePrivacy(); wx.setClipboardData({ data: url }); }
    catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '无法复制链接', icon: 'none' }); }
  },
  openFile(path: string) {
    wx.openDocument({ filePath: path, fileType: 'pdf', showMenu: true, fail: () => wx.showToast({ title: '无法打开 PDF 文件', icon: 'none' }) });
  },
  openSaved(event: Event) { this.openFile(this.data.saved[Number(event.currentTarget.dataset.index)].path); },
  deleteSaved(event: Event) {
    const index = Number(event.currentTarget.dataset.index);
    const row = this.data.saved[index];
    wx.showModal({ title: '删除本地 PDF？', content: row.title, success: (result) => {
      if (!result.confirm) return;
      wx.getFileSystemManager().unlink({ filePath: row.path, complete: () => {
        const saved = this.data.saved.filter((_, i) => i !== index);
        wx.setStorageSync(this.storageKey(), saved);
        this.setData({ saved });
      } });
    } });
  },
  retry() { void this.search(); },
});
