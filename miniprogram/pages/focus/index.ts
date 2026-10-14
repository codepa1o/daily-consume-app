import { getAccount, request } from '../../services/api';
import { POMODORO_SUBSCRIBE_TEMPLATE_ID } from '../../config';
import { dateKey } from '../../services/dates';

type Task = { id: number; title: string };
type Settings = { focus_minutes: number; short_break_minutes: number; long_break_minutes: number; rounds_per_long_break: number };
type Session = { task_title: string; duration_minutes: number; started_at: string };
type Phase = 'idle' | 'focus' | 'shortBreak' | 'longBreak' | 'focusComplete' | 'breakComplete' | 'saveFailed';
type TimerState = { phase: Phase; endAt: number | null; remainingMs: number; taskId: number | null; taskTitle: string; startedAt: string; requestId: string; durationMinutes: number; reminderId?: string };
type InputEvent = { detail: { value: string } };
type TapEvent = { currentTarget: { dataset: Record<string, string> } };
const statePrefix = 'daily_consume_pomodoro_';
let ticker: ReturnType<typeof setInterval> | undefined;

function makeRequestId() { return Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join(''); }
function initialState(settings: Settings): TimerState { return { phase: 'idle', endAt: null, remainingMs: settings.focus_minutes * 60000, taskId: null, taskTitle: '', startedAt: '', requestId: '', durationMinutes: settings.focus_minutes }; }

Page({
  data: {
    settings: { focus_minutes: 25, short_break_minutes: 5, long_break_minutes: 15, rounds_per_long_break: 4 } as Settings,
    tasks: [] as Task[], sessions: [] as Session[], selectedTaskId: 0, selectedTaskTitle: '',
    phase: 'idle' as Phase, remainingMs: 25 * 60000, timerText: '25:00', taskTitle: '', paused: false, focusedMinutes: 0,
    newTaskTitle: '', settingsOpen: false, settingsDraft: { focus_minutes: '25', short_break_minutes: '5', long_break_minutes: '15', rounds_per_long_break: '4' },
    backgroundReminderReady: Boolean(POMODORO_SUBSCRIBE_TEMPLATE_ID),
    loading: false, saving: false, error: '', today: dateKey(),
  },

  onShow() { void this.load(); },
  onHide() { if (ticker) clearInterval(ticker); ticker = undefined; },
  onUnload() { if (ticker) clearInterval(ticker); ticker = undefined; },

  storageKey() { return `${statePrefix}${getAccount()?.id ?? 0}`; },
  readState(): TimerState | null { return wx.getStorageSync<TimerState | null>(this.storageKey()) || null; },
  persist(state: TimerState | null) {
    if (state) wx.setStorageSync(this.storageKey(), state);
    else wx.removeStorageSync(this.storageKey());
  },
  setTimerState(state: TimerState) {
    this.persist(state);
    this.setData({ phase: state.phase, remainingMs: state.remainingMs, timerText: this.formatTime(state.remainingMs), taskTitle: state.taskTitle, paused: ['focus', 'shortBreak', 'longBreak'].includes(state.phase) && state.endAt == null });
  },

  async load() {
    this.setData({ loading: true, error: '' });
    try {
      const [settings, tasks, sessions] = await Promise.all([
        request<Settings>('GET', 'pomodoro/settings'),
        request<Task[]>('GET', 'pomodoro/tasks'),
        request<Session[]>('GET', 'pomodoro/sessions', undefined, true, { start: this.data.today, end: this.data.today }),
      ]);
      const timer = this.readState() ?? initialState(settings);
      const selectedTaskId = tasks.some((task) => task.id === timer.taskId) ? timer.taskId! : tasks[0]?.id ?? 0;
      this.setData({ settings, tasks, sessions, selectedTaskId,
        selectedTaskTitle: tasks.find((task) => task.id === selectedTaskId)?.title ?? '',
        focusedMinutes: sessions.reduce((sum, session) => sum + session.duration_minutes, 0), settingsDraft: {
        focus_minutes: String(settings.focus_minutes), short_break_minutes: String(settings.short_break_minutes),
        long_break_minutes: String(settings.long_break_minutes), rounds_per_long_break: String(settings.rounds_per_long_break),
      }, loading: false });
      this.setTimerState(timer);
      if ((timer.phase === 'focus' || timer.phase === 'shortBreak' || timer.phase === 'longBreak') && timer.endAt) {
        if (timer.endAt <= Date.now()) void this.finishPhase(timer);
        else this.startTicker();
      }
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '加载失败，请重试' }); }
  },

  startTicker() {
    if (ticker) clearInterval(ticker);
    ticker = setInterval(() => {
      const state = this.readState();
      if (!state?.endAt) return;
      const remainingMs = Math.max(0, state.endAt - Date.now());
      if (remainingMs <= 0) {
        if (ticker) clearInterval(ticker);
        ticker = undefined;
        void this.finishPhase({ ...state, remainingMs: 0, endAt: null });
      } else this.setData({ remainingMs, timerText: this.formatTime(remainingMs), paused: false });
    }, 1000);
  },

  async finishPhase(state: TimerState) {
    if (state.phase === 'focus') {
      await this.saveCompletedFocus(state);
      return;
    }
    const next = { ...state, phase: 'breakComplete' as Phase, endAt: null, remainingMs: 0, reminderId: '' };
    this.setTimerState(next);
    wx.showToast({ title: '休息结束', icon: 'none' });
  },

  selectTask(event: InputEvent) {
    const task = this.data.tasks[Number(event.detail.value)];
    this.setData({ selectedTaskId: task?.id ?? 0, selectedTaskTitle: task?.title ?? '' });
  },
  onNewTask(event: InputEvent) { this.setData({ newTaskTitle: event.detail.value }); },
  async addTask() {
    const title = this.data.newTaskTitle.trim();
    if (!title || title.length > 120) { wx.showToast({ title: '事项需为 1–120 个字', icon: 'none' }); return; }
    try {
      const task = await request<Task>('POST', 'pomodoro/tasks', { title });
      this.setData({ tasks: [task, ...this.data.tasks], selectedTaskId: task.id, selectedTaskTitle: task.title, newTaskTitle: '' });
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '添加失败' }); }
  },
  deleteTask(event: TapEvent) {
    const task = this.data.tasks[Number(event.currentTarget.dataset.index)];
    wx.showModal({ title: '删除专注事项？', content: '历史专注记录会保留。', success: async (result) => {
      if (!result.confirm) return;
      try {
        await request('DELETE', 'pomodoro/tasks', undefined, true, { id: String(task.id) });
        const tasks = this.data.tasks.filter((item) => item.id !== task.id);
        this.setData({ tasks, selectedTaskId: tasks[0]?.id ?? 0, selectedTaskTitle: tasks[0]?.title ?? '' });
      } catch (error) { this.setData({ error: error instanceof Error ? error.message : '删除失败' }); }
    } });
  },

  startFocus() {
    const task = this.data.tasks.find((item) => item.id === this.data.selectedTaskId);
    if (!task) { wx.showToast({ title: '请先添加并选择专注事项', icon: 'none' }); return; }
    const now = new Date();
    const remainingMs = this.data.settings.focus_minutes * 60000;
    const state: TimerState = { phase: 'focus', endAt: Date.now() + remainingMs, remainingMs, taskId: task.id, taskTitle: task.title, startedAt: now.toISOString(), requestId: makeRequestId(), durationMinutes: this.data.settings.focus_minutes };
    this.setTimerState(state);
    this.startTicker();
    this.requestReminder(state);
  },
  startBreak() {
    const completed = this.data.sessions.length;
    const long = completed > 0 && completed % this.data.settings.rounds_per_long_break === 0;
    const remainingMs = (long ? this.data.settings.long_break_minutes : this.data.settings.short_break_minutes) * 60000;
    const current = this.readState() ?? initialState(this.data.settings);
    const state = { ...current, phase: long ? 'longBreak' as Phase : 'shortBreak' as Phase, endAt: Date.now() + remainingMs, remainingMs, taskTitle: '', taskId: null, reminderId: '' };
    this.setTimerState(state);
    this.startTicker();
    this.requestReminder(state);
  },
  togglePause() {
    const state = this.readState();
    if (!state || !['focus', 'shortBreak', 'longBreak'].includes(state.phase)) return;
    if (state.endAt) {
      if (ticker) clearInterval(ticker);
      ticker = undefined;
      const remainingMs = Math.max(0, state.endAt - Date.now());
      void this.cancelReminder(state.reminderId);
      this.setTimerState({ ...state, endAt: null, remainingMs, reminderId: '' });
    } else {
      const resumed = { ...state, endAt: Date.now() + state.remainingMs, reminderId: '' };
      this.setTimerState(resumed);
      this.startTicker();
      this.requestReminder(resumed);
    }
  },
  requestReminder(state: TimerState) {
    const templateId = POMODORO_SUBSCRIBE_TEMPLATE_ID;
    if (!templateId || !state.endAt) return;
    wx.requestSubscribeMessage({
      tmplIds: [templateId],
      success: (result) => {
        if ((result as Record<string, string>)[templateId] !== 'accept') return;
        const reminderId = makeRequestId();
        request('POST', 'pomodoro/reminders', {
          client_request_id: reminderId,
          trigger_at: new Date(state.endAt!).toISOString(),
          phase: state.phase,
          task_title: state.taskTitle,
        }).then(() => {
          const current = this.readState();
          if (current?.phase === state.phase && current.endAt === state.endAt) this.setTimerState({ ...current, reminderId });
          else void this.cancelReminder(reminderId);
        }).catch(() => wx.showToast({ title: '后台提醒未启用，前台计时仍会继续', icon: 'none' }));
      },
      fail: () => wx.showToast({ title: '未订阅后台提醒，前台计时仍会继续', icon: 'none' }),
    });
  },
  async cancelReminder(reminderId?: string) {
    if (!reminderId) return;
    try { await request('DELETE', 'pomodoro/reminders', undefined, true, { request_id: reminderId }); }
    catch (_) {}
  },
  endFocus() {
    wx.showModal({ title: '结束本轮专注？', content: '未完成的专注时段不会计入记录。', success: (result) => {
      if (result.confirm) {
        if (ticker) clearInterval(ticker);
        ticker = undefined;
        void this.cancelReminder(this.readState()?.reminderId);
        this.persist(null);
        this.setData({ phase: 'idle', remainingMs: this.data.settings.focus_minutes * 60000, taskTitle: '' });
      }
    } });
  },
  endBreak() {
    if (ticker) clearInterval(ticker);
    ticker = undefined;
    const state = this.readState();
    if (state) { void this.cancelReminder(state.reminderId); this.setTimerState({ ...state, phase: 'breakComplete', endAt: null, remainingMs: 0, reminderId: '' }); }
  },
  endCurrent() {
    if (this.data.phase === 'focus') this.endFocus();
    else this.endBreak();
  },
  skipBreak() { this.persist(null); this.setData({ phase: 'idle', remainingMs: this.data.settings.focus_minutes * 60000, taskTitle: '' }); },

  async saveCompletedFocus(state?: TimerState | null) {
    state = state === undefined ? this.readState() : state;
    if (!state?.taskId || !state.startedAt || !state.requestId) return;
    this.setData({ saving: true, phase: 'saveFailed' });
    const completedAt = new Date().toISOString();
    try {
      await request('POST', 'pomodoro/sessions', {
        client_request_id: state.requestId,
        task_id: state.taskId,
        task_title: state.taskTitle,
        duration_minutes: state.durationMinutes,
        started_at: state.startedAt,
        completed_at: completedAt,
      });
      const next = { ...state, phase: 'focusComplete' as Phase, endAt: null, remainingMs: 0, reminderId: '' };
      this.setTimerState(next);
      const sessions = await request<Session[]>('GET', 'pomodoro/sessions', undefined, true, { start: this.data.today, end: this.data.today });
      this.setData({ sessions, focusedMinutes: sessions.reduce((sum, session) => sum + session.duration_minutes, 0) });
      wx.showToast({ title: '专注记录已同步', icon: 'success' });
    } catch (error) {
      this.setTimerState({ ...state, phase: 'saveFailed', endAt: null, remainingMs: 0 });
      this.setData({ error: error instanceof Error ? error.message : '专注记录同步失败' });
    } finally { this.setData({ saving: false }); }
  },
  retrySave() { void this.saveCompletedFocus(this.readState()); },

  onSettingInput(event: InputEvent & TapEvent) {
    const field = String(event.currentTarget.dataset.field) as keyof Settings;
    this.setData({ [`settingsDraft.${field}`]: String(event.detail.value) });
  },
  openSettings() { this.setData({ settingsOpen: true }); },
  closeSettings() { this.setData({ settingsOpen: false }); },
  async saveSettings() {
    const draft = this.data.settingsDraft;
    const settings: Settings = {
      focus_minutes: Number(draft.focus_minutes), short_break_minutes: Number(draft.short_break_minutes),
      long_break_minutes: Number(draft.long_break_minutes), rounds_per_long_break: Number(draft.rounds_per_long_break),
    };
    if (!Number.isInteger(settings.focus_minutes) || settings.focus_minutes < 1 || settings.focus_minutes > 120 ||
        !Number.isInteger(settings.short_break_minutes) || settings.short_break_minutes < 1 || settings.short_break_minutes > 60 ||
        !Number.isInteger(settings.long_break_minutes) || settings.long_break_minutes < 1 || settings.long_break_minutes > 120 ||
        !Number.isInteger(settings.rounds_per_long_break) || settings.rounds_per_long_break < 2 || settings.rounds_per_long_break > 12) {
      wx.showToast({ title: '请检查计时设置范围', icon: 'none' }); return;
    }
    try {
      await request('PUT', 'pomodoro/settings', settings);
      this.setData({ settings, settingsOpen: false });
      const timer = this.readState();
      if (!timer || timer.phase === 'idle') this.setData({ remainingMs: settings.focus_minutes * 60000 });
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '设置保存失败' }); }
  },
  retry() { void this.load(); },
  formatTime(milliseconds?: number) {
    milliseconds = milliseconds ?? this.data.remainingMs;
    const seconds = Math.ceil(milliseconds / 1000);
    return `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
  },
});
