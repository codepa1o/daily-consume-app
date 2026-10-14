import { HttpMethod, request } from '../../services/api';
import { dateKey, shiftDate } from '../../services/dates';

type Settings = { cycle_length: number | null; period_length: number | null; paused: boolean };
type Period = { id?: number; start_date: string; end_date: string | null; bleeding_dates: string[] };
type HealthDay = { date: string; flow: string; pain: number; symptoms: string[]; mood: string; spotting: boolean; notes: string };
type HealthData = { settings: Settings; periods: Period[]; days: HealthDay[] };
type Cell = { date: string; day: string; type: string; selected: boolean; future: boolean };
type Event = { detail: { value: string | number | boolean }; currentTarget: { dataset: Record<string, string> } };
const symptoms = ['腹胀', '头痛', '腰酸', '疲劳', '乳房胀痛', '恶心', '失眠'];
const moods = ['', '平静', '开心', '低落', '烦躁', '焦虑'];
const flows = [{ value: 'none', label: '无' }, { value: 'light', label: '少' }, { value: 'medium', label: '中' }, { value: 'heavy', label: '多' }];

function median(values: number[]): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

function prediction(data: HealthData) {
  const periods = [...data.periods].sort((a, b) => a.start_date.localeCompare(b.start_date));
  const cycles: number[] = [];
  for (let i = 1; i < periods.length; i++) {
    if (periods[i - 1].end_date) cycles.push(Math.round((new Date(`${periods[i].start_date}T12:00:00`).getTime() - new Date(`${periods[i - 1].start_date}T12:00:00`).getTime()) / 86400000));
  }
  const cycleLength = cycles.length >= 3 ? median(cycles.slice(-6)) : data.settings.cycle_length;
  const periodsLength = periods.filter((period) => period.end_date).map((period) => period.bleeding_dates.length);
  const periodLength = periodsLength.length ? median(periodsLength.slice(-6)) : data.settings.period_length;
  const latest = periods[periods.length - 1];
  const nextStart = !data.settings.paused && latest && cycleLength ? shiftDate(latest.start_date, cycleLength) : '';
  const nextEnd = nextStart && periodLength ? shiftDate(nextStart, periodLength - 1) : '';
  const ovulation = nextStart ? shiftDate(nextStart, -14) : '';
  const fertileStart = ovulation ? shiftDate(ovulation, -5) : '';
  return { cycles, cycleLength, periodLength, latest, nextStart, nextEnd, ovulation, fertileStart };
}

function classify(date: string, data: HealthData, guess: ReturnType<typeof prediction>, today: string): string {
  if (data.periods.some((period) => period.bleeding_dates.includes(date))) return 'period';
  if (!guess.nextStart || date < today) return 'ordinary';
  if (date >= guess.nextStart && guess.nextEnd && date <= guess.nextEnd) return 'predicted';
  if (date === guess.ovulation) return 'ovulation';
  if (guess.fertileStart && guess.ovulation && date >= guess.fertileStart && date < guess.ovulation) return 'fertile';
  return 'ordinary';
}

function monthCells(month: string, data: HealthData, selected: string, today: string): Cell[] {
  const [year, number] = month.split('-').map(Number);
  const offset = (new Date(year, number - 1, 1).getDay() + 6) % 7;
  const count = new Date(year, number, 0).getDate();
  const guess = prediction(data);
  const result: Cell[] = [];
  for (let i = 0; i < offset; i++) result.push({ date: '', day: '', type: 'empty', selected: false, future: false });
  for (let day = 1; day <= count; day++) {
    const date = `${month}-${day.toString().padStart(2, '0')}`;
    result.push({ date, day: String(day), type: classify(date, data, guess, today), selected: date === selected, future: date > today });
  }
  while (result.length % 7) result.push({ date: '', day: '', type: 'empty', selected: false, future: false });
  return result;
}

Page({
  data: {
    today: dateKey(), selectedDate: dateKey(), month: dateKey().slice(0, 7), monthTitle: '',
    weekdays: ['一', '二', '三', '四', '五', '六', '日'], cells: [] as Cell[],
    data: null as HealthData | null, isBleeding: false, settings: { cycle_length: '', period_length: '', paused: false },
    selectedDay: { flow: 'none', pain: 0, symptoms: [] as string[], mood: '', spotting: false, notes: '' },
    symptomOptions: [] as Array<{ value: string; selected: boolean }>, moodOptions: [] as Array<{ value: string; selected: boolean }>, flowOptions: flows, painOptions: [0, 1, 2, 3],
    nextStart: '', nextEnd: '', predictionBasis: '', cycleHistory: [] as number[], currentPeriod: null as Period | null,
    loading: false, saving: false, settingsOpen: false, error: '',
  },

  onShow() { void this.load(); },
  async load() {
    this.setData({ loading: true, error: '' });
    try {
      const data = await request<HealthData>('GET', 'female-health');
      const guess = prediction(data);
      const selectedDay = data.days.find((day) => day.date === this.data.selectedDate) ?? { date: this.data.selectedDate, flow: 'none', pain: 0, symptoms: [], mood: '', spotting: false, notes: '' };
      const currentPeriod = data.periods.find((period) => this.data.selectedDate >= period.start_date && (!period.end_date || this.data.selectedDate <= period.end_date));
      const basis = data.settings.paused ? '预测已暂停；实际记录与历史仍会保留。'
        : guess.cycles.length >= 3 ? `参考最近 ${Math.min(guess.cycles.length, 6)} 个周期的中位数${Math.max(...guess.cycles.slice(-6)) - Math.min(...guess.cycles.slice(-6)) > 7 ? '；周期差异较大，预测参考性有限。' : '。'}`
        : guess.cycleLength ? '基于你填写的周期估计；历史记录较少。' : '记录经期并填写周期长度后显示预测。';
      this.setData({
        data,
        isBleeding: data.periods.some((period) => period.bleeding_dates.includes(this.data.selectedDate)),
        settings: { cycle_length: data.settings.cycle_length == null ? '' : String(data.settings.cycle_length), period_length: data.settings.period_length == null ? '' : String(data.settings.period_length), paused: data.settings.paused },
        selectedDay: { flow: selectedDay.flow, pain: selectedDay.pain, symptoms: selectedDay.symptoms, mood: selectedDay.mood, spotting: selectedDay.spotting, notes: selectedDay.notes },
        symptomOptions: symptoms.map((value) => ({ value, selected: selectedDay.symptoms.includes(value) })),
        moodOptions: moods.map((value) => ({ value, selected: selectedDay.mood === value })),
        nextStart: guess.nextStart, nextEnd: guess.nextEnd, predictionBasis: basis, cycleHistory: guess.cycles.slice(-6), currentPeriod: currentPeriod ?? null,
        cells: monthCells(this.data.month, data, this.data.selectedDate, this.data.today),
        monthTitle: `${this.data.month.slice(0, 4)}年${Number(this.data.month.slice(5))}月`, loading: false,
      });
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '加载失败，请重试' }); }
  },

  onDayTap(event: Event) {
    const date = String(event.currentTarget.dataset.date || '');
    if (!date || date > this.data.today) return;
    this.setData({ selectedDate: date, month: date.slice(0, 7) });
    void this.load();
  },
  previousMonth() {
    const [year, month] = this.data.month.split('-').map(Number);
    const next = dateKey(new Date(year, month - 2, 1)).slice(0, 7);
    this.setData({ month: next, selectedDate: `${next}-01` });
    void this.load();
  },
  nextMonth() {
    const [year, month] = this.data.month.split('-').map(Number);
    const next = dateKey(new Date(year, month, 1)).slice(0, 7);
    if (next <= this.data.today.slice(0, 7)) { this.setData({ month: next, selectedDate: `${next}-01` }); void this.load(); }
  },
  onCycleLength(event: Event) { this.setData({ 'settings.cycle_length': String(event.detail.value) }); },
  onPeriodLength(event: Event) { this.setData({ 'settings.period_length': String(event.detail.value) }); },
  onPaused(event: Event) { this.setData({ 'settings.paused': Boolean(event.detail.value) }); },
  openSettings() { this.setData({ settingsOpen: true }); },
  closeSettings() { this.setData({ settingsOpen: false }); },
  async saveSettings() {
    const cycle = this.data.settings.cycle_length === '' ? null : Number(this.data.settings.cycle_length);
    const period = this.data.settings.period_length === '' ? null : Number(this.data.settings.period_length);
    if ((cycle !== null && (!Number.isInteger(cycle) || cycle < 1 || cycle > 365)) || (period !== null && (!Number.isInteger(period) || period < 1 || period > 90))) {
      wx.showToast({ title: '周期长度为 1–365 天，经期长度为 1–90 天', icon: 'none' }); return;
    }
    await this.performSave('female-health/settings', { cycle_length: cycle, period_length: period, paused: this.data.settings.paused }, '设置已保存');
    this.setData({ settingsOpen: false });
  },
  toggleSymptom(event: Event) {
    const value = String(event.currentTarget.dataset.value);
    const list = this.data.selectedDay.symptoms;
    const selected = list.includes(value) ? list.filter((item) => item !== value) : [...list, value];
    this.setData({ 'selectedDay.symptoms': selected, symptomOptions: symptoms.map((item) => ({ value: item, selected: selected.includes(item) })) });
  },
  setFlow(event: Event) { this.setData({ 'selectedDay.flow': String(event.currentTarget.dataset.value) }); },
  setPain(event: Event) { this.setData({ 'selectedDay.pain': Number(event.currentTarget.dataset.value) }); },
  setMood(event: Event) {
    const mood = String(event.currentTarget.dataset.value);
    this.setData({ 'selectedDay.mood': mood, moodOptions: moods.map((item) => ({ value: item, selected: mood === item })) });
  },
  setSpotting(event: Event) { this.setData({ 'selectedDay.spotting': Boolean(event.detail.value) }); },
  setNotes(event: Event) { this.setData({ 'selectedDay.notes': String(event.detail.value) }); },
  async saveDay() {
    await this.performSave('female-health/days', { date: this.data.selectedDate, ...this.data.selectedDay }, '当天记录已保存');
  },
  async deleteDay() {
    const day = this.data.data?.days.find((item) => item.date === this.data.selectedDate);
    if (!day) return;
    wx.showModal({ title: '删除当天健康记录？', content: '经期日历记录不会被删除。', success: async (result) => {
      if (result.confirm) await this.performSave('female-health/days', undefined, '当天记录已删除', 'DELETE', { date: this.data.selectedDate });
    } });
  },
  async toggleBleeding() {
    const data = this.data.data;
    if (!data) return;
    const date = this.data.selectedDate;
    const existing = data.periods.find((period) => date >= period.start_date && (!period.end_date || date <= period.end_date))
      ?? data.periods.find((period) => period.bleeding_dates.includes(date));
    let body: Period;
    if (!existing) {
      body = { start_date: date, end_date: null, bleeding_dates: [date] };
    } else {
      const dates = existing.bleeding_dates.includes(date) ? existing.bleeding_dates.filter((day) => day !== date) : [...existing.bleeding_dates, date].sort();
      if (!dates.length) { wx.showToast({ title: '经期至少保留一个实际出血日', icon: 'none' }); return; }
      body = { id: existing.id, start_date: dates[0], end_date: existing.end_date ? dates[dates.length - 1] : null, bleeding_dates: dates };
    }
    await this.performSave('female-health/periods', body, existing ? '出血日期已更新' : '经期已记录');
  },
  async finishPeriod() {
    const period = this.data.currentPeriod;
    if (!period || period.end_date) return;
    const dates = period.bleeding_dates.includes(this.data.selectedDate) ? period.bleeding_dates : [...period.bleeding_dates, this.data.selectedDate].sort();
    await this.performSave('female-health/periods', { ...period, end_date: dates[dates.length - 1], bleeding_dates: dates }, '经期已结束');
  },
  async deletePeriod() {
    if (!this.data.currentPeriod?.id) return;
    wx.showModal({ title: '删除这段经期？', content: '相关实际出血日期会从经期历史中移除。', success: async (result) => {
      if (result.confirm) await this.performSave('female-health/periods', undefined, '经期记录已删除', 'DELETE', { id: String(this.data.currentPeriod!.id) });
    } });
  },
  async clearHealth() {
    wx.showModal({ title: '清除全部女性健康数据？', content: '经期、每日记录和周期设置都将删除，此操作无法恢复。', success: async (result) => {
      if (result.confirm) await this.performSave('female-health', undefined, '健康数据已清除', 'DELETE', { reset_settings: 'true' });
    } });
  },
  async performSave(path: string, body?: Record<string, unknown>, success = '已保存', method: HttpMethod = 'PUT', query?: Record<string, string>) {
    this.setData({ saving: true, error: '' });
    try {
      await request(method, path, body, true, query);
      wx.showToast({ title: success, icon: 'success' });
      await this.load();
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '操作失败，请重试' }); }
    finally { this.setData({ saving: false }); }
  },
  retry() { void this.load(); },
});
