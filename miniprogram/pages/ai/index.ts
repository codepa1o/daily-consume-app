import { request } from '../../services/api';
import { dateKey } from '../../services/dates';

type Report = { title: string; subtitle?: string; summary: string; highlights?: Array<{ label: string; value: string | number; unit?: string; caption?: string }>; sections?: Array<{ title: string; items: Array<{ value: string }> }>; suggestions?: string[]; notice?: string | null };
type InputEvent = { detail: { value: string } };
type TapEvent = { currentTarget: { dataset: Record<string, string> } };

Page({
  data: { today: dateKey(), date: dateKey(), mode: 'daily' as 'daily' | 'profile', report: null as Report | null, loading: false, error: '' },
  onShow() { if (!this.data.report) void this.generate(); },
  onDate(event: InputEvent) { this.setData({ date: event.detail.value, mode: 'daily' }); void this.generate(); },
  setMode(event: TapEvent) { this.setData({ mode: event.currentTarget.dataset.value as 'daily' | 'profile', report: null }); void this.generate(); },
  async generate() {
    this.setData({ loading: true, error: '', report: null });
    try {
      const report = this.data.mode === 'profile'
        ? await request<Report>('POST', 'ai/profile-analysis')
        : await request<Report>('POST', 'ai/daily-summary', { date: this.data.date });
      this.setData({ report, loading: false });
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '生成失败，请稍后重试' }); }
  },
  retry() { void this.generate(); },
});
