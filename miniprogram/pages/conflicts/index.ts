import { getAccount, request } from '../../services/api';
import { dateKey, dateRange } from '../../services/dates';

type Conflict = { id: number; conflict_date: string; title: string; summary: string; created_by: number; status: string; agreement: string; follow_up_date: string | null; agreement_version: number; agreement_confirmed_by: number[]; reflection_count: number };
type Event = { detail: { value: string | number | boolean }; currentTarget: { dataset: Record<string, string> } };
function requestId() { return Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join(''); }

Page({
  data: {
    today: dateKey(), lastDate: `${new Date().getFullYear() + 10}-12-31`, month: dateKey().slice(0, 7), conflicts: [] as Conflict[], selected: null as Record<string, any> | null,
    userId: getAccount()?.id ?? 0, loading: false, saving: false, error: '',
    createOpen: false, conflictDate: dateKey(), title: '', summary: '',
    observations: '', feelings: '', needs: '', myPart: '', requestText: '', published: false,
    agreement: '', followUpDate: '', agreementVersion: 0,
    comment: '', conflictRequestId: '', commentRequestId: '',
  },
  onShow() { this.setData({ userId: getAccount()?.id ?? 0 }); void this.load(); },
  async load() {
    const range = dateRange(`${this.data.month}-01`, 'month');
    this.setData({ loading: true, error: '' });
    try {
      const conflicts = await request<Conflict[]>('GET', 'couple/conflicts', undefined, true, range);
      this.setData({ conflicts, loading: false });
      if (this.data.selected?.id) await this.openConflict(Number(this.data.selected.id));
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '加载反思记录失败' }); }
  },
  previousMonth() {
    const [year, month] = this.data.month.split('-').map(Number);
    this.setData({ month: dateKey(new Date(year, month - 2, 1)).slice(0, 7) }); void this.load();
  },
  nextMonth() {
    const [year, month] = this.data.month.split('-').map(Number);
    const next = dateKey(new Date(year, month, 1)).slice(0, 7);
    if (next <= this.data.today.slice(0, 7)) { this.setData({ month: next }); void this.load(); }
  },
  onCreateDate(event: Event) { this.setData({ conflictDate: String(event.detail.value) }); },
  onCreateTitle(event: Event) { this.setData({ title: String(event.detail.value) }); },
  onCreateSummary(event: Event) { this.setData({ summary: String(event.detail.value) }); },
  onReflection(event: Event) { this.setData({ [String(event.currentTarget.dataset.field)]: String(event.detail.value) }); },
  onPublished(event: Event) { this.setData({ published: Boolean(event.detail.value) }); },
  onAgreement(event: Event) { this.setData({ agreement: String(event.detail.value) }); },
  onFollowUp(event: Event) { this.setData({ followUpDate: String(event.detail.value) }); },
  onComment(event: Event) { this.setData({ comment: String(event.detail.value) }); },
  closeCreate() { this.setData({ createOpen: false }); },
  closeConflict() { this.setData({ selected: null }); },
  openCreate() { this.setData({ createOpen: true, conflictDate: dateKey(), title: '', summary: '', conflictRequestId: requestId() }); },
  async createConflict() {
    const title = this.data.title.trim();
    if (!title) { wx.showToast({ title: '请填写主题', icon: 'none' }); return; }
    this.setData({ saving: true, error: '' });
    try {
      const result = await request<{ id: number }>('POST', 'couple/conflicts', { conflict_date: this.data.conflictDate, title, summary: this.data.summary.trim(), client_request_id: this.data.conflictRequestId || requestId() });
      this.setData({ createOpen: false, saving: false, conflictRequestId: '' });
      await this.load();
      await this.openConflict(result.id);
    } catch (error) { this.setData({ saving: false, error: error instanceof Error ? error.message : '创建反思记录失败' }); }
  },
  async openConflict(id: number) {
    this.setData({ loading: true, error: '' });
    try {
      const selected = await request<Record<string, any>>('GET', `couple/conflicts/${id}`);
      const own = (selected.reflections ?? []).find((item: any) => item.author_id === this.data.userId) ?? {};
      this.setData({ selected, loading: false, observations: own.observations ?? '', feelings: own.feelings ?? '', needs: own.needs ?? '', myPart: own.my_part ?? '', requestText: own.request ?? '', published: Boolean(own.published), agreement: selected.agreement ?? '', followUpDate: selected.follow_up_date ?? '', agreementVersion: selected.agreement_version ?? 0 });
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '读取反思详情失败' }); }
  },
  async saveReflection() {
    const id = Number(this.data.selected?.id);
    if (!id) return;
    if (![this.data.observations, this.data.feelings, this.data.needs, this.data.myPart, this.data.requestText].some((value) => value.trim())) {
      wx.showToast({ title: '至少填写一项反思', icon: 'none' }); return;
    }
    this.setData({ saving: true });
    try {
      await request('PUT', `couple/conflicts/${id}/reflection`, { observations: this.data.observations, feelings: this.data.feelings, needs: this.data.needs, my_part: this.data.myPart, request: this.data.requestText, published: this.data.published });
      await this.openConflict(id);
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '保存反思失败' }); }
    finally { this.setData({ saving: false }); }
  },
  async saveAgreement() {
    const selected = this.data.selected;
    if (!selected || !this.data.agreement.trim()) { wx.showToast({ title: '请填写共同约定', icon: 'none' }); return; }
    this.setData({ saving: true });
    try {
      await request('PUT', `couple/conflicts/${selected.id}/agreement`, { agreement: this.data.agreement.trim(), follow_up_date: this.data.followUpDate || null, expected_version: this.data.agreementVersion });
      await this.openConflict(selected.id);
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '保存约定失败，请刷新后重试' }); }
    finally { this.setData({ saving: false }); }
  },
  async addComment() {
    const id = Number(this.data.selected?.id);
    if (!id || !this.data.comment.trim()) return;
    try {
      const client_request_id = this.data.commentRequestId || requestId();
      this.setData({ commentRequestId: client_request_id });
      await request('POST', `couple/conflicts/${id}/comments`, { content: this.data.comment.trim(), client_request_id });
      this.setData({ comment: '', commentRequestId: '' }); await this.openConflict(id);
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '留言失败' }); }
  },
  deleteConflict() {
    const selected = this.data.selected;
    if (!selected || selected.created_by !== this.data.userId) return;
    wx.showModal({ title: '删除这段关系反思？', content: '双方的反思和留言都会删除。', success: async (result) => {
      if (!result.confirm) return;
      try { await request('DELETE', `couple/conflicts/${selected.id}`); this.setData({ selected: null }); await this.load(); }
      catch (error) { this.setData({ error: error instanceof Error ? error.message : '删除失败' }); }
    } });
  },
  retry() { void this.load(); },
});
