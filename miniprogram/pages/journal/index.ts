import { request } from '../../services/api';
import { dateKey, shiftDate } from '../../services/dates';

type JournalEntry = {
  id: number; entry_date: string; kind: 'diary' | 'memo'; title: string; content: string;
  is_todo: boolean; completed: boolean; version: number;
};
type DaySummary = { entry_date: string; diaries: number; memos: number; pending: number; completed: number };
type CalendarCell = { date: string; day: string; summary: DaySummary | null; selected: boolean; future: boolean };
type EntryPage = { items: JournalEntry[]; total: number; has_more: boolean };
type InputEvent = { detail: { value: string } };
type TapEvent = { currentTarget: { dataset: Record<string, string> } };

function cellsForMonth(month: string, summaries: DaySummary[], selected: string, today: string): CalendarCell[] {
  const [year, monthNumber] = month.split('-').map(Number);
  const first = new Date(year, monthNumber - 1, 1);
  const offset = (first.getDay() + 6) % 7;
  const count = new Date(year, monthNumber, 0).getDate();
  const cells: CalendarCell[] = [];
  for (let i = 0; i < offset; i++) cells.push({ date: '', day: '', summary: null, selected: false, future: false });
  for (let day = 1; day <= count; day++) {
    const date = `${month}-${day.toString().padStart(2, '0')}`;
    cells.push({ date, day: String(day), summary: summaries.find((row) => row.entry_date === date) ?? null, selected: date === selected, future: date > today });
  }
  while (cells.length % 7) cells.push({ date: '', day: '', summary: null, selected: false, future: false });
  return cells;
}

function requestId(): string {
  return Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join('');
}

Page({
  data: {
    today: dateKey(), date: dateKey(), month: dateKey().slice(0, 7), monthTitle: '',
    lastDate: `${new Date().getFullYear() + 10}-12-31`,
    cells: [] as CalendarCell[], weekdays: ['一', '二', '三', '四', '五', '六', '日'],
    entries: [] as JournalEntry[], loading: false, saving: false, error: '',
    editorVisible: false, dirty: false, editingId: 0, editingVersion: 0, pendingCreateRequestId: '',
    editDate: dateKey(), kind: 'diary' as 'diary' | 'memo', title: '', content: '', isTodo: false, completed: false,
    searchQuery: '', searchResults: [] as JournalEntry[], searchTotal: 0, searchOffset: 0, searchHasMore: false, searching: false,
  },

  onShow() { void this.load(); },
  onBackPress() {
    if (!this.data.editorVisible) return false;
    this.closeEditor();
    return true;
  },
  async load() {
    this.setData({ loading: true, error: '' });
    try {
      const [calendar, entries] = await Promise.all([
        request<{ days: DaySummary[] }>('GET', 'journal/calendar', undefined, true, { month: this.data.month }),
        request<EntryPage>('GET', 'journal/entries', undefined, true, { date: this.data.date, limit: '50', offset: '0' }),
      ]);
      this.setData({
        cells: cellsForMonth(this.data.month, calendar.days, this.data.date, this.data.today),
        monthTitle: `${this.data.month.slice(0, 4)}年${Number(this.data.month.slice(5))}月`,
        entries: entries.items,
        loading: false,
      });
    } catch (error) {
      this.setData({ loading: false, error: error instanceof Error ? error.message : '加载失败，请重试' });
    }
  },

  selectDate(event: TapEvent) {
    const date = event.currentTarget.dataset.date;
    if (!date || date > this.data.today) return;
    this.setData({ date, month: date.slice(0, 7) });
    void this.load();
  },
  previousMonth() {
    const [year, month] = this.data.month.split('-').map(Number);
    const date = new Date(year, month - 2, 1);
    const monthKey = dateKey(date).slice(0, 7);
    const selected = `${monthKey}-01`;
    this.setData({ month: monthKey, date: selected });
    void this.load();
  },
  nextMonth() {
    const [year, month] = this.data.month.split('-').map(Number);
    const date = new Date(year, month, 1);
    const monthKey = dateKey(date).slice(0, 7);
    if (monthKey <= this.data.today.slice(0, 7)) {
      this.setData({ month: monthKey, date: `${monthKey}-01` });
      void this.load();
    }
  },
  previousDay() { const date = shiftDate(this.data.date, -1); this.setData({ date, month: date.slice(0, 7) }); void this.load(); },
  nextDay() { const date = shiftDate(this.data.date, 1); if (date <= this.data.today) { this.setData({ date, month: date.slice(0, 7) }); void this.load(); } },
  onSearchInput(event: InputEvent) { this.setData({ searchQuery: event.detail.value }); },
  async search() {
    const q = this.data.searchQuery.trim();
    if (!q) { this.setData({ searchResults: [], searchTotal: 0, searchHasMore: false }); return; }
    this.setData({ searching: true, error: '', searchOffset: 0 });
    try {
      const result = await request<EntryPage>('GET', 'journal/entries', undefined, true, { q, limit: '50', offset: '0' });
      this.setData({ searchResults: result.items, searchTotal: result.total, searchHasMore: result.has_more, searchOffset: result.items.length, searching: false });
    } catch (error) { this.setData({ searching: false, error: error instanceof Error ? error.message : '搜索失败，请重试' }); }
  },
  async moreSearchResults() {
    this.setData({ searching: true });
    try {
      const result = await request<EntryPage>('GET', 'journal/entries', undefined, true, { q: this.data.searchQuery.trim(), limit: '50', offset: String(this.data.searchOffset) });
      this.setData({ searchResults: [...this.data.searchResults, ...result.items], searchHasMore: result.has_more, searchOffset: this.data.searchOffset + result.items.length, searching: false });
    } catch (error) { this.setData({ searching: false, error: error instanceof Error ? error.message : '加载失败，请重试' }); }
  },
  clearSearch() { this.setData({ searchQuery: '', searchResults: [], searchTotal: 0, searchHasMore: false }); },

  async newEntry() {
    this.setData({ editorVisible: true, dirty: false, editingId: 0, editingVersion: 0, pendingCreateRequestId: '', editDate: this.data.date, kind: 'diary', title: '', content: '', isTodo: false, completed: false });
  },
  async editEntry(event: TapEvent) {
    this.setData({ loading: true, error: '' });
    try {
      const entry = await request<JournalEntry>('GET', `journal/entries/${event.currentTarget.dataset.id}`);
      this.setData({ loading: false, editorVisible: true, dirty: false, editingId: entry.id, editingVersion: entry.version, editDate: entry.entry_date, kind: entry.kind, title: entry.title, content: entry.content, isTodo: entry.is_todo, completed: entry.completed });
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '无法读取记录' }); }
  },
  onEditDate(event: InputEvent) { this.setData({ editDate: event.detail.value, dirty: true }); },
  onTitle(event: InputEvent) { this.setData({ title: event.detail.value, dirty: true }); },
  onContent(event: InputEvent) { this.setData({ content: event.detail.value, dirty: true }); },
  setKind(event: TapEvent) { this.setData({ kind: event.currentTarget.dataset.kind as 'diary' | 'memo', dirty: true, isTodo: false, completed: false }); },
  setTodo(event: InputEvent) { this.setData({ isTodo: Boolean(event.detail.value), completed: false, dirty: true }); },
  setCompleted(event: InputEvent) { this.setData({ completed: Boolean(event.detail.value), dirty: true }); },
  closeEditor() {
    if (!this.data.dirty) { this.setData({ editorVisible: false, pendingCreateRequestId: '' }); return; }
    wx.showModal({ title: '放弃未保存的修改？', content: '当前编辑内容还没有保存。', success: (result) => { if (result.confirm) this.setData({ editorVisible: false, pendingCreateRequestId: '' }); } });
  },
  async saveEntry() {
    const body = { entry_date: this.data.editDate, kind: this.data.kind, title: this.data.title.trim(), content: this.data.content.trim(), is_todo: this.data.isTodo, completed: this.data.completed };
    if (this.data.kind === 'diary' && (!body.content || this.data.editDate > this.data.today)) { wx.showToast({ title: '日记需填写正文且不能记录未来日期', icon: 'none' }); return; }
    if (this.data.kind === 'memo' && !body.title && !body.content) { wx.showToast({ title: '备忘至少填写标题或正文', icon: 'none' }); return; }
    const clientRequestId = this.data.editingId ? '' : this.data.pendingCreateRequestId || requestId();
    if (!this.data.editingId && !this.data.pendingCreateRequestId) this.setData({ pendingCreateRequestId: clientRequestId });
    this.setData({ saving: true, error: '' });
    try {
      await request(this.data.editingId ? 'PUT' : 'POST', this.data.editingId ? `journal/entries/${this.data.editingId}` : 'journal/entries', {
        ...body,
        ...(this.data.editingId ? { expected_version: this.data.editingVersion } : { client_request_id: clientRequestId }),
      });
      this.setData({ saving: false, editorVisible: false, dirty: false, pendingCreateRequestId: '', date: this.data.editDate, month: this.data.editDate.slice(0, 7) });
      wx.showToast({ title: this.data.editingId ? '已更新' : '已保存', icon: 'success' });
      await this.load();
    } catch (error) {
      this.setData({ saving: false, error: error instanceof Error ? error.message : '保存失败，请刷新后重试' });
    }
  },
  async toggleCompleted(event: TapEvent) {
    const entry = this.data.entries.find((item) => item.id === Number(event.currentTarget.dataset.id));
    if (!entry) return;
    try {
      const latest = await request<JournalEntry>('GET', `journal/entries/${entry.id}`);
      if (latest.version !== entry.version) { wx.showToast({ title: '记录已修改，请刷新后重试', icon: 'none' }); await this.load(); return; }
      await request('PUT', `journal/entries/${entry.id}`, { entry_date: latest.entry_date, kind: latest.kind, title: latest.title, content: latest.content, is_todo: true, completed: !latest.completed, expected_version: latest.version });
      await this.load();
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '更新失败，请重试' }); }
  },
  async deleteEntry(event: TapEvent) {
    const entry = this.data.entries.find((item) => item.id === Number(event.currentTarget.dataset.id));
    if (!entry) return;
    wx.showModal({ title: '删除这条记录？', content: '删除后无法恢复。', success: async (result) => {
      if (!result.confirm) return;
      try { await request('DELETE', `journal/entries/${entry.id}`, undefined, true, { expected_version: String(entry.version) }); await this.load(); }
      catch (error) { this.setData({ error: error instanceof Error ? error.message : '删除失败，请刷新后重试' }); }
    } });
  },
  openSearchResult(event: TapEvent) {
    const entry = this.data.searchResults.find((item) => item.id === Number(event.currentTarget.dataset.id));
    if (entry) { this.setData({ date: entry.entry_date, month: entry.entry_date.slice(0, 7) }); void this.load(); }
  },
  retry() { void this.load(); },
});
