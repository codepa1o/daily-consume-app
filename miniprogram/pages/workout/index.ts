import { request } from '../../services/api';
import { dateKey, dateRange, shiftDate } from '../../services/dates';

type Muscle = { name: string; color_value: number; built_in: number; color: string };
type Plan = { weekday: number; muscles: string[]; is_rest: number };
type Action = { name: string; sets: string; reps: string; key: string };
type Log = { date: string; muscles: Array<{ name: string; color: number; displayColor?: string }>; actions: Array<{ name: string; sets: number; reps: number }> };
type Event = { detail: { value: string | number | boolean }; currentTarget: { dataset: Record<string, string> } };

const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const palette = [0xffc87962, 0xff6d8fa4, 0xffc59c4d, 0xff718665, 0xff9b7ca0, 0xff527c74, 0xffce8c62, 0xff7381a1];
let actionSequence = 0;
let checkinTimer: ReturnType<typeof setTimeout> | undefined;
let checkinFired = false;

function monthCells(month: string, logs: Log[], plans: Plan[]) {
  const [year, monthNumber] = month.split('-').map(Number);
  const first = new Date(year, monthNumber - 1, 1);
  const count = new Date(year, monthNumber, 0).getDate();
  const offset = (first.getDay() + 6) % 7;
  const cells: Array<{ date: string; day: number; checked: boolean; rest: boolean } | { date: ''; day: ''; checked: false; rest: false }> = [];
  for (let i = 0; i < offset; i++) cells.push({ date: '', day: '', checked: false, rest: false });
  for (let day = 1; day <= count; day++) {
    const key = `${month}-${day.toString().padStart(2, '0')}`;
    const weekday = ((new Date(year, monthNumber - 1, day).getDay() + 6) % 7) + 1;
    cells.push({ date: key, day, checked: logs.some((log) => log.date === key), rest: plans.find((plan) => plan.weekday === weekday)?.is_rest === 1 });
  }
  return cells;
}

function monthCalendarRange(month: string) {
  const first = `${month}-01`;
  const [year, monthNumber] = month.split('-').map(Number);
  const last = dateKey(new Date(year, monthNumber, 0));
  const firstWeekday = ((new Date(`${first}T12:00:00`).getDay() + 6) % 7);
  const lastWeekday = ((new Date(`${last}T12:00:00`).getDay() + 6) % 7);
  return { start: shiftDate(first, -firstWeekday), end: shiftDate(last, 6 - lastWeekday) };
}

function colorHex(value: number): string {
  return `#${(value >>> 0).toString(16).slice(-6)}`;
}

Page({
  data: {
    today: dateKey(),
    selectedDate: dateKey(),
    month: dateKey().slice(0, 7),
    monthTitle: '',
    monthCells: [] as ReturnType<typeof monthCells>,
    weekdays,
    weekLabels: ['一', '二', '三', '四', '五', '六', '日'],
    weeklyGoals: [1, 2, 3, 4, 5, 6, 7],
    muscles: [] as Muscle[],
    selectedMuscles: [] as string[],
    plans: [] as Plan[],
    logs: [] as Log[],
    weeklyGoal: 3,
    weekCount: 0,
    monthCount: 0,
    muscleStats: [] as Array<{ name: string; count: number; color: string }>,
    isRest: false,
    currentLog: null as Log | null,
    actions: [] as Action[],
    saving: false,
    loading: false,
    error: '',
    newMuscleName: '',
    newMuscleColor: palette[0],
    palette: palette.map(colorHex),
    planWeekday: ((new Date().getDay() + 6) % 7) + 1,
    planMuscles: [] as string[],
    planRest: false,
    planSaving: false,
    weeklyGoalInput: '3',
  },

  onShow() { void this.load(); },
  onHide() { if (checkinTimer) clearTimeout(checkinTimer); checkinTimer = undefined; },

  async load() {
    this.setData({ loading: true, error: '' });
    const range = monthCalendarRange(this.data.month);
    try {
      const [muscles, settings, plans, logs] = await Promise.all([
        request<Array<Omit<Muscle, 'color'>>>('GET', 'workout/muscles'),
        request<{ weekly_goal: number }>('GET', 'workout/settings'),
        request<Plan[]>('GET', 'workout/plans'),
        request<Log[]>('GET', 'workout/logs', undefined, true, { start: range.start, end: range.end }),
      ]);
      const normalizedPlans = weekdays.map((_, index) => plans.find((plan) => plan.weekday === index + 1) ?? { weekday: index + 1, muscles: [], is_rest: 0 });
      const normalizedMuscles = muscles.map((muscle) => ({ ...muscle, color: colorHex(muscle.color_value) }));
      const normalizedLogs = logs.map((log) => ({ ...log, muscles: log.muscles.map((muscle) => ({ ...muscle, displayColor: colorHex(muscle.color) })) }));
      const currentLog = normalizedLogs.find((log) => log.date === this.data.selectedDate) ?? null;
      const selectedPlan = normalizedPlans.find((plan) => plan.weekday === this.weekday(this.data.selectedDate));
      const selectedMuscles = currentLog ? currentLog.muscles.map((muscle) => muscle.name) : selectedPlan?.muscles ?? [];
      const week = dateRange(this.data.selectedDate, 'week');
      const weekCount = normalizedLogs.filter((log) => log.date >= week.start && log.date <= week.end).length;
      const monthCount = normalizedLogs.filter((log) => log.date.startsWith(this.data.month)).length;
      const counts = new Map<string, { count: number; color: string }>();
      for (const log of normalizedLogs.filter((row) => row.date.startsWith(this.data.month))) {
        for (const muscle of log.muscles) {
          const current = counts.get(muscle.name) ?? { count: 0, color: muscle.displayColor ?? '#64765a' };
          current.count++;
          counts.set(muscle.name, current);
        }
      }
      const plan = normalizedPlans.find((row) => row.weekday === this.data.planWeekday);
      this.setData({
        muscles: normalizedMuscles.map((muscle) => ({ ...muscle, selected: selectedMuscles.includes(muscle.name), planSelected: (plan?.muscles ?? []).includes(muscle.name) })),
        plans: normalizedPlans,
        logs: normalizedLogs,
        weeklyGoal: settings.weekly_goal,
        weeklyGoalInput: String(settings.weekly_goal),
        weekCount,
        monthCount,
        muscleStats: Array.from(counts, ([name, value]) => ({ name, ...value })).sort((a, b) => b.count - a.count),
        currentLog,
        isRest: selectedPlan?.is_rest === 1,
        selectedMuscles,
        actions: currentLog?.actions.map((action) => ({ ...action, sets: String(action.sets), reps: String(action.reps), key: `action-${++actionSequence}` })) ?? [],
        planMuscles: plan?.muscles ?? [],
        planRest: plan?.is_rest === 1,
        monthTitle: `${this.data.month.slice(0, 4)}年${Number(this.data.month.slice(5))}月`,
        monthCells: monthCells(this.data.month, logs, normalizedPlans),
        loading: false,
      });
    } catch (error) {
      this.setData({ loading: false, error: error instanceof Error ? error.message : '加载失败，请重试' });
    }
  },

  weekday(key: string) { return ((new Date(`${key}T12:00:00`).getDay() + 6) % 7) + 1; },
  onDayTap(event: Event) {
    const date = String(event.currentTarget.dataset.date || '');
    if (!date || date > this.data.today) return;
    this.setData({ selectedDate: date });
    void this.load();
  },
  previousMonth() {
    const [year, month] = this.data.month.split('-').map(Number);
    const date = new Date(year, month - 2, 1);
    const key = dateKey(date).slice(0, 7);
    this.setData({ month: key });
    void this.load();
  },
  nextMonth() {
    const [year, month] = this.data.month.split('-').map(Number);
    const date = new Date(year, month, 1);
    const key = dateKey(date).slice(0, 7);
    if (key <= this.data.today.slice(0, 7)) { this.setData({ month: key }); void this.load(); }
  },
  previousDay() {
    const selectedDate = shiftDate(this.data.selectedDate, -1);
    this.setData({ selectedDate, month: selectedDate.slice(0, 7) });
    void this.load();
  },
  nextDay() {
    const selectedDate = shiftDate(this.data.selectedDate, 1);
    if (selectedDate <= this.data.today) { this.setData({ selectedDate, month: selectedDate.slice(0, 7) }); void this.load(); }
  },

  toggleMuscle(event: Event) {
    if (this.data.currentLog || this.data.isRest) return;
    const name = String(event.currentTarget.dataset.name);
    const selectedMuscles = this.data.selectedMuscles.includes(name)
      ? this.data.selectedMuscles.filter((item) => item !== name)
      : [...this.data.selectedMuscles, name];
    this.setData({ selectedMuscles, muscles: this.data.muscles.map((item) => ({ ...item, selected: selectedMuscles.includes(item.name) })) });
  },
  startCheckin() {
    if (this.data.currentLog || this.data.isRest || this.data.loading || this.data.saving) return;
    checkinFired = false;
    checkinTimer = setTimeout(() => {
      checkinTimer = undefined;
      checkinFired = true;
      void this.saveCheckin();
    }, 2000);
  },
  endCheckin() {
    if (checkinTimer) {
      clearTimeout(checkinTimer);
      checkinTimer = undefined;
      wx.showToast({ title: '请长按 2 秒打卡', icon: 'none' });
    }
  },
  checkinTap() {
    if (!this.data.currentLog || checkinFired) return;
    wx.showModal({ title: '撤销训练打卡？', content: '这会删除所选日期的训练记录。', success: (result) => {
      if (result.confirm) void this.deleteCheckin();
    } });
  },
  async saveCheckin() {
    if (!this.data.selectedMuscles.length) {
      wx.showToast({ title: '请先选择训练部位', icon: 'none' });
      return;
    }
    const actions = this.data.actions.filter((action) => action.name.trim());
    if (actions.some((action) => !Number.isInteger(Number(action.sets)) || Number(action.sets) < 1 || !Number.isInteger(Number(action.reps)) || Number(action.reps) < 1)) {
      wx.showToast({ title: '请检查动作组数和次数', icon: 'none' });
      return;
    }
    const muscles = this.data.selectedMuscles.map((name) => {
      const muscle = this.data.muscles.find((item) => item.name === name)!;
      return { name, color: muscle.color_value };
    });
    this.setData({ saving: true, error: '' });
    try {
      await request('POST', 'workout/logs', {
        date: this.data.selectedDate,
        muscles,
        actions: actions.map((action) => ({ name: action.name.trim(), sets: Number(action.sets), reps: Number(action.reps) })),
      });
      wx.showToast({ title: '打卡成功，今天也很棒', icon: 'success' });
      await this.load();
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : '打卡失败，请重试' });
    } finally { this.setData({ saving: false }); }
  },
  async deleteCheckin() {
    this.setData({ saving: true, error: '' });
    try {
      await request('DELETE', 'workout/logs', undefined, true, { date: this.data.selectedDate });
      wx.showToast({ title: '已撤销打卡', icon: 'success' });
      await this.load();
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : '撤销失败，请重试' });
    } finally { this.setData({ saving: false }); }
  },

  onActionInput(event: Event) {
    const index = Number(event.currentTarget.dataset.index);
    const field = String(event.currentTarget.dataset.field) as 'name' | 'sets' | 'reps';
    this.setData({ [`actions[${index}].${field}`]: String(event.detail.value) });
  },
  addAction() { this.setData({ actions: [...this.data.actions, { name: '', sets: '3', reps: '10', key: `action-${++actionSequence}` }] }); },
  removeAction(event: Event) {
    const index = Number(event.currentTarget.dataset.index);
    this.setData({ actions: this.data.actions.filter((_, i) => i !== index) });
  },

  onGoalChange(event: Event) { this.setData({ weeklyGoalInput: String(event.detail.value) }); },
  onPlanWeekday(event: Event) {
    const planWeekday = Number(event.detail.value) + 1;
    const plan = this.data.plans.find((item) => item.weekday === planWeekday);
    const planMuscles = plan?.muscles ?? [];
    this.setData({ planWeekday, planMuscles, planRest: plan?.is_rest === 1, muscles: this.data.muscles.map((item) => ({ ...item, planSelected: planMuscles.includes(item.name) })) });
  },
  onPlanRest(event: Event) {
    const planRest = Boolean(event.detail.value);
    const planMuscles = planRest ? [] : this.data.planMuscles;
    this.setData({ planRest, planMuscles, muscles: this.data.muscles.map((item) => ({ ...item, planSelected: planMuscles.includes(item.name) })) });
  },
  togglePlanMuscle(event: Event) {
    if (this.data.planRest) return;
    const name = String(event.currentTarget.dataset.name);
    const planMuscles = this.data.planMuscles.includes(name) ? this.data.planMuscles.filter((item) => item !== name) : [...this.data.planMuscles, name];
    this.setData({ planMuscles, muscles: this.data.muscles.map((item) => ({ ...item, planSelected: planMuscles.includes(item.name) })) });
  },
  async saveSchedule() {
    const weekly_goal = Number(this.data.weeklyGoalInput);
    if (!Number.isInteger(weekly_goal) || weekly_goal < 1 || weekly_goal > 7) {
      wx.showToast({ title: '每周目标应为 1–7 天', icon: 'none' });
      return;
    }
    const plans = this.data.plans.map((plan) => plan.weekday === this.data.planWeekday
      ? { ...plan, muscles: this.data.planRest ? [] : this.data.planMuscles, is_rest: this.data.planRest ? 1 : 0 }
      : plan);
    this.setData({ planSaving: true });
    try {
      await request('PUT', 'workout/schedule', { weekly_goal, plans });
      wx.showToast({ title: '计划已保存', icon: 'success' });
      await this.load();
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : '保存计划失败' });
    } finally { this.setData({ planSaving: false }); }
  },

  onNewMuscleName(event: Event) { this.setData({ newMuscleName: String(event.detail.value) }); },
  selectMuscleColor(event: Event) { this.setData({ newMuscleColor: palette[Number(event.currentTarget.dataset.index)] }); },
  async addMuscle() {
    const name = this.data.newMuscleName.trim();
    if (!name || name.length > 12) { wx.showToast({ title: '部位名称需为 1–12 个字', icon: 'none' }); return; }
    try {
      await request('POST', 'workout/muscles', { name, color_value: this.data.newMuscleColor });
      this.setData({ newMuscleName: '' });
      await this.load();
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '添加失败' }); }
  },
  async changeMuscleColor(event: Event) {
    const muscle = this.data.muscles[Number(event.currentTarget.dataset.index)];
    const color_value = palette[(palette.indexOf(muscle.color_value) + 1) % palette.length];
    try { await request('PUT', 'workout/muscles', { name: muscle.name, color_value }); await this.load(); }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : '修改颜色失败' }); }
  },
  async deleteMuscle(event: Event) {
    const muscle = this.data.muscles[Number(event.currentTarget.dataset.index)];
    wx.showModal({ title: '删除训练部位？', content: `将删除“${muscle.name}”并从训练计划中移除。历史记录会保留。`, success: async (result) => {
      if (!result.confirm) return;
      try { await request('DELETE', 'workout/muscles', undefined, true, { name: muscle.name }); await this.load(); }
      catch (error) { this.setData({ error: error instanceof Error ? error.message : '删除失败' }); }
    } });
  },
  retry() { void this.load(); },
});
