import { downloadFile, getAccount, request } from '../../services/api';
import { dateKey } from '../../services/dates';
import { authorizePrivacy } from '../../services/privacy';

type Space = { id: number; title: string; since_date: string; created_by: number; members: Array<{ id: number; nickname: string }> };
type Memory = { id: number; author_id: number; author_name: string; memory_date: string; published_date: string; title: string; content: string; mood: string; photo_count: number; display_mode: string; has_photo: boolean; coverPath?: string };
type InputEvent = { detail: { value: string } };
type TapEvent = { currentTarget: { dataset: Record<string, string> } };
const moods = ['', '开心', '平静', '想你', '疲惫', '难过'];
const effects = ['拍立得显影', '翻面留言', '双人拼贴', '惊喜刮刮卡', '回忆星空', '立体照片'];
function requestId() { return Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join(''); }
function togetherDuration(since: string, today: string) {
  const start = new Date(`${since}T12:00:00`);
  const now = new Date(`${today}T12:00:00`);
  const daysTogether = Math.floor((now.getTime() - start.getTime()) / 86400000) + 1;
  let years = now.getFullYear() - start.getFullYear();
  const yearDate = (value: number) => new Date(value, start.getMonth(), Math.min(start.getDate(), new Date(value, start.getMonth() + 1, 0).getDate()));
  let cursor = yearDate(start.getFullYear() + years);
  if (cursor > now) { years--; cursor = yearDate(start.getFullYear() + years); }
  let months = (now.getFullYear() - cursor.getFullYear()) * 12 + now.getMonth() - cursor.getMonth();
  const monthDate = (offset: number) => {
    const first = new Date(cursor.getFullYear(), cursor.getMonth() + offset, 1);
    return new Date(first.getFullYear(), first.getMonth(), Math.min(cursor.getDate(), new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate()));
  };
  let monthCursor = monthDate(months);
  if (monthCursor > now) { months--; monthCursor = monthDate(months); }
  const days = Math.floor((now.getTime() - monthCursor.getTime()) / 86400000);
  const timeTogether = [years > 0 ? `${years} 年` : '', months > 0 ? `${months} 个月` : '', days > 0 ? `${days} 天` : ''].filter(Boolean).join('') || '今天开始';
  return { daysTogether, timeTogether };
}
function readBase64(path: string): Promise<string> {
  return new Promise((resolve, reject) => wx.getFileSystemManager().readFile({ filePath: path, encoding: 'base64', success: (result) => resolve(String(result.data)), fail: () => reject(new Error('无法读取照片')) }));
}

Page({
  data: {
    today: dateKey(), date: dateKey(), tab: 'memories' as 'memories' | 'pair', space: null as Space | null,
    userId: getAccount()?.id ?? 0,
    noSpace: false, loading: false, saving: false, error: '', daysTogether: 0, timeTogether: '', inviteCode: '', invitePreview: null as Record<string, unknown> | null,
    title: '两个人的小窝', sinceDate: dateKey(), memories: [] as Memory[], hasMore: false, offset: 0,
    pair: [] as Memory[], selectedMemory: null as Record<string, any> | null, memoryPhotos: [] as string[],
    comments: [] as Array<Record<string, any>>, comment: '', reaction: '', effects, effectIndex: 0, flipped: false, scratched: false,
    pairItems: [] as Array<Memory & { coverPath?: string }>,
    editorOpen: false, memoryDate: dateKey(), memoryTitle: '', memoryContent: '', memoryMood: '', displayMode: 'grid', photoFiles: [] as Array<{ path: string; name: string; base64: string }>,
    memoryRequestId: '', commentRequestId: '',
    moods,
  },
  onLoad(options: Record<string, string | undefined>) {
    if (options.inviteCode) {
      this.setData({ inviteCode: options.inviteCode.toUpperCase() });
      setTimeout(() => { void this.previewInvite(); }, 0);
    }
  },
  onShow() { this.setData({ userId: getAccount()?.id ?? 0 }); void this.loadSpace(); },
  onShareAppMessage() {
    const code = this.data.inviteCode;
    return { title: code ? '邀请你加入我们的情侣空间' : this.data.space?.title ?? '情侣空间', path: `/pages/couple/index${code ? `?inviteCode=${code}` : ''}` };
  },
  async loadSpace() {
    this.setData({ loading: true, error: '' });
    try {
      const space = await request<Space | null>('GET', 'couple/space');
      if (!space) { this.setData({ noSpace: true, loading: false }); return; }
      const duration = togetherDuration(space.since_date, this.data.today);
      this.setData({ space, noSpace: false, sinceDate: space.since_date, ...duration, loading: false });
      await this.loadMemories(true);
    } catch (error) {
      if ((error as { statusCode?: number }).statusCode === 404) this.setData({ noSpace: true, loading: false });
      else this.setData({ loading: false, error: error instanceof Error ? error.message : '加载空间失败' });
    }
  },
  onTitle(event: InputEvent) { this.setData({ title: event.detail.value }); },
  onSinceDate(event: InputEvent) { this.setData({ sinceDate: event.detail.value }); },
  onInviteCode(event: InputEvent) { this.setData({ inviteCode: event.detail.value.toUpperCase() }); },
  onDate(event: InputEvent) { this.setData({ date: event.detail.value }); if (this.data.tab === 'pair') void this.loadPair(); },
  onMemoryDate(event: InputEvent) { this.setData({ memoryDate: event.detail.value }); },
  onMemoryTitle(event: InputEvent) { this.setData({ memoryTitle: event.detail.value }); },
  onMemoryContent(event: InputEvent) { this.setData({ memoryContent: event.detail.value }); },
  onComment(event: InputEvent) { this.setData({ comment: event.detail.value }); },
  selectMood(event: TapEvent) { this.setData({ memoryMood: event.currentTarget.dataset.mood ?? '' }); },
  selectMode(event: TapEvent) { this.setData({ displayMode: event.currentTarget.dataset.mode as 'grid' | 'swipe' }); },
  async createSpace() {
    try {
      const space = await request<Space>('POST', 'couple/space', { title: this.data.title.trim(), since_date: this.data.sinceDate });
      this.setData({ space, noSpace: false });
      await this.loadSpace();
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '创建空间失败' }); }
  },
  async updateAnniversary(event: InputEvent) {
    const sinceDate = event.detail.value;
    this.setData({ sinceDate, ...togetherDuration(sinceDate, this.data.today) });
    try { await request('PUT', 'couple/space/anniversary', { since_date: sinceDate }); }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : '更新日期失败' }); }
  },
  async createInvite() {
    try { const result = await request<{ code: string }>('POST', 'couple/invite'); this.setData({ inviteCode: result.code }); }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : '生成邀请码失败' }); }
  },
  async previewInvite() {
    try { const invitePreview = await request<Record<string, unknown>>('POST', 'couple/invite/preview', { code: this.data.inviteCode.trim().toUpperCase() }); this.setData({ invitePreview }); }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : '邀请码无效' }); }
  },
  joinInvite() {
    wx.showModal({ title: '加入情侣空间？', content: `确认加入“${String(this.data.invitePreview?.title ?? '')}”吗？`, success: async (result) => {
      if (!result.confirm) return;
      try { await request('POST', 'couple/join', { code: this.data.inviteCode.trim().toUpperCase() }); this.setData({ invitePreview: null, inviteCode: '' }); await this.loadSpace(); }
      catch (error) { this.setData({ error: error instanceof Error ? error.message : '加入失败' }); }
    } });
  },
  async loadMemories(reset = false) {
    const offset = reset ? 0 : this.data.offset;
    this.setData({ loading: true, error: '' });
    try {
      const result = await request<{ items: Memory[]; has_more: boolean }>('GET', 'couple/memories', undefined, true, { offset: String(offset), limit: '30' });
      const rows = await Promise.all(result.items.map(async (item) => {
        if (!item.has_photo) return item;
        try { return { ...item, coverPath: await downloadFile(`couple/memories/${item.id}/photo`, { thumbnail: 'true' }) }; }
        catch (_) { return item; }
      }));
      const memories = reset ? rows : [...this.data.memories, ...rows];
      this.setData({ memories, hasMore: result.has_more, offset: offset + rows.length, loading: false });
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '读取回忆失败' }); }
  },
  async loadPair() {
    try {
      const result = await request<{ items: Memory[] }>('GET', 'couple/pair', undefined, true, { date: this.data.date });
      this.setData({ pair: result.items });
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '读取双人回忆失败' }); }
  },
  switchTab(event: TapEvent) {
    const tab = event.currentTarget.dataset.tab as 'memories' | 'pair';
    this.setData({ tab });
    if (tab === 'pair') void this.loadPair();
  },
  openConflicts() { wx.navigateTo({ url: '/pages/conflicts/index' }); },
  loadMore() { if (this.data.hasMore && !this.data.loading) void this.loadMemories(false); },
  newMemory() { this.setData({ editorOpen: true, memoryDate: this.data.date, memoryTitle: '', memoryContent: '', memoryMood: '', displayMode: 'grid', photoFiles: [], memoryRequestId: requestId() }); },
  closeEditor() { if (!this.data.saving) this.setData({ editorOpen: false }); },
  async choosePhotos() {
    try { await authorizePrivacy(); }
    catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '无法使用照片', icon: 'none' }); return; }
    wx.chooseMedia({ count: 9, mediaType: ['image'], sizeType: ['compressed'], sourceType: ['album', 'camera'], success: async (result) => {
      try {
        if (result.tempFiles.some((file) => file.size > 8 * 1024 * 1024)) {
          wx.showToast({ title: '单张照片不能超过 8 MB', icon: 'none' });
          return;
        }
        const files = await Promise.all(result.tempFiles.map(async (file) => ({ path: file.tempFilePath, name: file.tempFilePath.split('/').pop() || 'photo.jpg', base64: await readBase64(file.tempFilePath) })));
        const total = files.reduce((sum, file) => sum + file.base64.length, 0);
        if (files.some((file) => file.base64.length > 11184812) || total > 16777216) { wx.showToast({ title: '单张照片不能超过 8 MB，合计不能超过 12 MB', icon: 'none' }); return; }
        this.setData({ photoFiles: files });
      } catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '读取照片失败', icon: 'none' }); }
    } });
  },
  async saveMemory() {
    if (!this.data.memoryTitle.trim()) { wx.showToast({ title: '请填写标题', icon: 'none' }); return; }
    this.setData({ saving: true, error: '' });
    try {
      await request('POST', 'couple/memories', {
        client_request_id: this.data.memoryRequestId || requestId(), memory_date: this.data.memoryDate, title: this.data.memoryTitle.trim(), content: this.data.memoryContent.trim(), mood: this.data.memoryMood,
        display_mode: this.data.displayMode, photos_base64: this.data.photoFiles.map((file) => file.base64),
      });
      this.setData({ saving: false, editorOpen: false, memoryRequestId: '', date: this.data.memoryDate });
      wx.showToast({ title: '回忆已发布', icon: 'success' });
      await this.loadMemories(true);
    } catch (error) { this.setData({ saving: false, error: error instanceof Error ? error.message : '保存失败，请重试' }); }
  },
  async openMemory(event: TapEvent) {
    const id = Number(event.currentTarget.dataset.id);
    try {
      const detail = await request<Record<string, any>>('GET', `couple/memories/${id}`);
      const photoCount = detail.photo_count || (detail.has_photo ? 1 : 0);
      const photos = await Promise.all(Array.from({ length: photoCount }, (_, index) => downloadFile(index === 0 ? `couple/memories/${id}/photo` : `couple/memories/${id}/photos/${index}`, { thumbnail: 'false' }).catch(() => '')));
      const pair = await request<{ items: Memory[] }>('GET', 'couple/pair', undefined, true, { date: detail.memory_date }).catch(() => ({ items: [] as Memory[] }));
      const pairItems = await Promise.all(pair.items.map(async (item) => ({ ...item, coverPath: item.has_photo ? await downloadFile(`couple/memories/${item.id}/photo`, { thumbnail: 'true' }).catch(() => '') : '' })));
      this.setData({ selectedMemory: detail, memoryPhotos: photos.filter(Boolean), comments: detail.comments ?? [], reaction: detail.reactions?.find((row: any) => row.user_id === getAccount()?.id)?.emoji ?? '', effectIndex: 0, flipped: false, scratched: false, pairItems });
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '读取回忆失败' }); }
  },
  closeMemory() { this.setData({ selectedMemory: null, memoryPhotos: [], comments: [] }); },
  selectEffect(event: InputEvent) { this.setData({ effectIndex: Number(event.detail.value), flipped: false, scratched: false }); },
  toggleFlip() { this.setData({ flipped: !this.data.flipped }); },
  scratchReveal() { this.setData({ scratched: true }); },
  async addComment() {
    const id = Number(this.data.selectedMemory?.id);
    const content = this.data.comment.trim();
    if (!id || !content) return;
    try {
      const client_request_id = this.data.commentRequestId || requestId();
      this.setData({ commentRequestId: client_request_id });
      await request('POST', `couple/memories/${id}/comments`, { content, client_request_id });
      this.setData({ comment: '', commentRequestId: '' });
      await this.openMemory({ currentTarget: { dataset: { id: String(id) } } });
    }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : '留言失败' }); }
  },
  async setReaction(event: TapEvent) {
    const id = Number(this.data.selectedMemory?.id);
    const emoji = event.currentTarget.dataset.emoji;
    if (!id) return;
    try { await request('PUT', `couple/memories/${id}/reaction`, { emoji: this.data.reaction === emoji ? null : emoji }); await this.openMemory({ currentTarget: { dataset: { id: String(id) } } }); }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : '互动失败' }); }
  },
  deleteMemory() {
    const memory = this.data.selectedMemory;
    if (!memory || memory.author_id !== getAccount()?.id) return;
    wx.showModal({ title: '删除这条回忆？', content: '照片、留言和互动都会一起删除。', success: async (result) => {
      if (!result.confirm) return;
      try { await request('DELETE', `couple/memories/${memory.id}`); this.closeMemory(); await this.loadMemories(true); }
      catch (error) { this.setData({ error: error instanceof Error ? error.message : '删除失败' }); }
    } });
  },
  retry() { void this.loadSpace(); },
});
