import { HttpMethod, request } from '../../services/api';
import { dateKey } from '../../services/dates';

interface WeightRow { date: string; grams: number }
interface HeightRow { date: string; millimeters: number }
type PickerEvent = { detail: { value: string } };
type InputEvent = { detail: { value: string } };

Page({
  data: {
    today: dateKey(),
    date: dateKey(),
    weightInput: '',
    heightInput: '',
    goalInput: '',
    weights: [] as Array<WeightRow & { value: string }>,
    heights: [] as Array<HeightRow & { value: string }>,
    trend: [] as Array<{ date: string; value: string; height: number }>,
    latestWeight: '', latestWeightDate: '', latestHeight: '', latestHeightDate: '',
    loading: false,
    saving: '',
    error: '',
  },

  onShow() { void this.load(); },

  async load() {
    this.setData({ loading: true, error: '' });
    try {
      const [weights, heights, settings] = await Promise.all([
        request<WeightRow[]>('GET', 'weights'),
        request<HeightRow[]>('GET', 'heights'),
        request<{ goal_weight_grams: number | null }>('GET', 'body/settings'),
      ]);
      const date = this.data.date;
      const weightRows = [...weights].sort((a, b) => b.date.localeCompare(a.date));
      const heightRows = [...heights].sort((a, b) => b.date.localeCompare(a.date));
      const chartRows = [...weights].sort((a, b) => a.date.localeCompare(b.date)).slice(-14);
      const values = chartRows.map((row) => row.grams / 1000);
      const min = values.length ? Math.min(...values) : 0;
      const max = values.length ? Math.max(...values) : 0;
      this.setData({
        weights: weightRows.map((row) => ({ ...row, value: (row.grams / 1000).toFixed(1) })),
        heights: heightRows.map((row) => ({ ...row, value: (row.millimeters / 10).toFixed(1) })),
        latestWeight: weightRows[0] ? (weightRows[0].grams / 1000).toFixed(1) : '',
        latestWeightDate: weightRows[0]?.date ?? '',
        latestHeight: heightRows[0] ? (heightRows[0].millimeters / 10).toFixed(1) : '',
        latestHeightDate: heightRows[0]?.date ?? '',
        trend: chartRows.map((row) => {
          const value = row.grams / 1000;
          return {
            date: row.date.slice(5),
            value: value.toFixed(1),
            height: max === min ? 56 : Math.round(22 + 76 * (value - min) / (max - min)),
          };
        }),
        weightInput: weights.some((row) => row.date === date) ? (weights.find((row) => row.date === date)!.grams / 1000).toFixed(1) : '',
        heightInput: heights.some((row) => row.date === date) ? (heights.find((row) => row.date === date)!.millimeters / 10).toFixed(1) : '',
        goalInput: settings.goal_weight_grams == null ? '' : (settings.goal_weight_grams / 1000).toFixed(1),
        loading: false,
      });
    } catch (error) {
      this.setData({ loading: false, error: error instanceof Error ? error.message : '加载失败，请重试' });
    }
  },

  onDateChange(event: PickerEvent) {
    const date = event.detail.value as string;
    if (date > this.data.today) return;
    this.setData({ date });
    void this.load();
  },

  onWeightInput(event: InputEvent) { this.setData({ weightInput: event.detail.value }); },
  onHeightInput(event: InputEvent) { this.setData({ heightInput: event.detail.value }); },
  onGoalInput(event: InputEvent) { this.setData({ goalInput: event.detail.value }); },

  async saveWeight() {
    const value = Number(this.data.weightInput);
    if (!Number.isFinite(value) || value < 20 || value > 300) {
      wx.showToast({ title: '体重范围为 20–300 kg', icon: 'none' });
      return;
    }
    await this.save('weight', 'weights', { date: this.data.date, grams: Math.round(value * 1000) });
  },

  async saveHeight() {
    const value = Number(this.data.heightInput);
    if (!Number.isFinite(value) || value < 80 || value > 250) {
      wx.showToast({ title: '身高范围为 80–250 cm', icon: 'none' });
      return;
    }
    await this.save('height', 'heights', { date: this.data.date, millimeters: Math.round(value * 10) });
  },

  async saveGoal() {
    const input = this.data.goalInput.trim();
    const value = input === '' ? null : Number(input);
    if (value !== null && (!Number.isFinite(value) || value < 20 || value > 300)) {
      wx.showToast({ title: '目标体重范围为 20–300 kg', icon: 'none' });
      return;
    }
    await this.save('goal', 'body/settings', { goal_weight_grams: value === null ? null : Math.round(value * 1000) }, 'PUT');
  },

  async save(key: string, path: string, body: Record<string, unknown>, method: HttpMethod = 'PUT') {
    this.setData({ saving: key, error: '' });
    try {
      await request(method, path, body);
      wx.showToast({ title: '已保存', icon: 'success' });
      await this.load();
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : '保存失败，请重试' });
    } finally {
      this.setData({ saving: '' });
    }
  },

  retry() { void this.load(); },
});
