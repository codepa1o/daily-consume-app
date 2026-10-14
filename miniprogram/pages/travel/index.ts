import { getAccount, request } from '../../services/api';
import { dateKey } from '../../services/dates';
import { authorizePrivacy } from '../../services/privacy';

type Point = { name: string; address?: string; description?: string; location?: { longitude: number; latitude: number }; image_url?: string; estimated_cost?: number; visit_duration?: number; type?: string };
type Event = { detail: { value: string | number | boolean }; currentTarget: { dataset: Record<string, string> } };
type ExportedTrip = { name: string; path: string; createdAt: string };
const transports = ['公共交通', '地铁公交', '打车/网约车', '自驾', '租车自驾', '包车/私人司机', '高铁+市内交通', '飞机+市内交通', '骑行/步行', '混合交通', '无障碍交通优先'];
const stays = ['经济型酒店', '舒适型酒店', '高端酒店', '豪华酒店', '亲子酒店', '民宿'];
const budgetLevels = [{ id: 'limited', label: '节省' }, { id: 'standard', label: '标准' }, { id: 'comfortable', label: '舒适' }, { id: 'premium', label: '高端' }, { id: 'luxury', label: '奢华' }];
const preferences = ['历史文化', '自然风光', '美食', '购物', '艺术', '休闲', '亲子友好', '老人友好', '小众路线', '夜游', '摄影打卡', '博物馆', '城市漫步', '户外徒步', '主题乐园', '避开人群'];

function companionType(adults: number, children: number, elders: number) {
  if (children) return 'family_with_children';
  if (elders) return 'family_with_elders';
  if (adults === 1) return 'solo';
  if (adults === 2) return 'couple';
  if (adults > 2) return 'friends';
  return 'other';
}

Page({
  data: {
    today: dateKey(), city: '', startDate: '', endDate: '', adults: 2, children: 0, elders: 0,
    transportation: '公共交通', accommodation: '经济型酒店', transportIndex: 0, stayIndex: 0, budgetLevels, budgetLevel: 'standard', budgetLevelIndex: 1, budgetAmount: '', strictBudget: false,
    transports, stays, preferenceOptions: preferences.map((value) => ({ value, selected: false })), selectedPreferences: [] as string[], freeText: '',
    loading: false, error: '', plan: null as Record<string, any> | null, fallback: false, editingPlan: false,
    dayIndex: 0, markers: [] as Array<Record<string, any>>, centerLatitude: 39.9, centerLongitude: 116.4,
    poiQuery: '', poiResults: [] as Point[], routeOrigin: '', routeDestination: '', routeType: 'walking', routeTypeIndex: 0, routeLabels: ['步行', '驾车', '公交'], routeResult: null as Record<string, any> | null,
    savedExports: [] as ExportedTrip[],
  },

  onShow() { this.loadExports(); },
  exportKey() { return `daily_consume_trip_exports_${getAccount()?.id ?? 0}`; },
  loadExports() { this.setData({ savedExports: wx.getStorageSync<ExportedTrip[]>(this.exportKey()) || [] }); },

  onCity(event: Event) { this.setData({ city: String(event.detail.value) }); },
  onFreeText(event: Event) { this.setData({ freeText: String(event.detail.value) }); },
  onBudget(event: Event) { this.setData({ budgetAmount: String(event.detail.value) }); },
  onBudgetStrict(event: Event) { this.setData({ strictBudget: Boolean(event.detail.value) }); },
  onStartDate(event: Event) { this.setData({ startDate: String(event.detail.value), endDate: '' }); },
  onEndDate(event: Event) { this.setData({ endDate: String(event.detail.value) }); },
  onTransport(event: Event) { const transportIndex = Number(event.detail.value); this.setData({ transportIndex, transportation: this.data.transports[transportIndex] }); },
  onAccommodation(event: Event) { const stayIndex = Number(event.detail.value); this.setData({ stayIndex, accommodation: this.data.stays[stayIndex] }); },
  onBudgetLevel(event: Event) { const budgetLevelIndex = Number(event.detail.value); this.setData({ budgetLevelIndex, budgetLevel: this.data.budgetLevels[budgetLevelIndex].id }); },
  selectBudgetLevel(event: Event) { const budgetLevelIndex = Number(event.currentTarget.dataset.index); this.setData({ budgetLevelIndex, budgetLevel: this.data.budgetLevels[budgetLevelIndex].id }); },
  onCount(event: Event) {
    const field = String(event.currentTarget.dataset.field) as 'adults' | 'children' | 'elders';
    const value = Number(event.detail.value);
    if (Number.isInteger(value) && value >= 0 && value <= 20) this.setData({ [field]: value });
  },
  togglePreference(event: Event) {
    const preference = String(event.currentTarget.dataset.value);
    const selected = this.data.selectedPreferences;
    const selectedPreferences = selected.includes(preference) ? selected.filter((item) => item !== preference) : [...selected, preference];
    this.setData({ selectedPreferences, preferenceOptions: preferences.map((value) => ({ value, selected: selectedPreferences.includes(value) })) });
  },
  travelDays() {
    if (!this.data.startDate || !this.data.endDate) return 0;
    return Math.floor((new Date(`${this.data.endDate}T12:00:00`).getTime() - new Date(`${this.data.startDate}T12:00:00`).getTime()) / 86400000) + 1;
  },
  async generate() {
    const total = this.data.adults + this.data.children + this.data.elders;
    const days = this.travelDays();
    const amount = this.data.budgetAmount.trim() ? Number(this.data.budgetAmount) : null;
    if (!this.data.city.trim() || !days || days > 30 || total < 1 || total > 30 || (amount !== null && (!Number.isInteger(amount) || amount < 0))) {
      wx.showToast({ title: '请检查城市、日期、人数和预算', icon: 'none' }); return;
    }
    this.setData({ loading: true, error: '', routeResult: null });
    try {
      const response = await request<Record<string, any>>('POST', 'travel/plan', {
        city: this.data.city.trim(), start_date: this.data.startDate, end_date: this.data.endDate, travel_days: days,
        transportation: this.data.transportation, accommodation: this.data.accommodation, preferences: this.data.selectedPreferences,
        free_text_input: this.data.freeText,
        party: { adults: this.data.adults, children: this.data.children, elders: this.data.elders, total, companion_type: companionType(this.data.adults, this.data.children, this.data.elders) },
        budget_constraint: { amount, scope: 'total', currency: 'CNY', budget_level: this.data.budgetLevel, strictness: amount == null ? 'none' : this.data.strictBudget ? 'hard' : 'soft' },
      });
      if (response.success !== true || !response.data) throw new Error(String(response.message ?? '行程生成失败'));
      this.setData({ plan: response.data, fallback: response.fallback === true, dayIndex: 0, loading: false, editingPlan: false });
      this.updateMap(response.data, 0);
    } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '行程生成失败，请重试' }); }
  },
  updateMap(plan: Record<string, any>, dayIndex: number) {
    const day = plan.days?.[dayIndex];
    const points: Point[] = [...(day?.hotel ? [day.hotel] : []), ...(day?.attractions ?? []), ...(day?.meals ?? [])];
    const markers: Array<Record<string, any>> = [];
    points.forEach((point, index) => {
      const location = point.location;
      if (location && Number.isFinite(location.latitude) && Number.isFinite(location.longitude)) {
        markers.push({ id: index, latitude: location.latitude, longitude: location.longitude, title: point.name, callout: { content: point.name, display: 'BYCLICK' } });
      }
    });
    const center = markers[0];
    this.setData({ markers, centerLatitude: center?.latitude ?? 39.9, centerLongitude: center?.longitude ?? 116.4 });
  },
  selectDay(event: Event) {
    const dayIndex = Number(event.currentTarget.dataset.index);
    if (!this.data.plan) return;
    this.setData({ dayIndex });
    this.updateMap(this.data.plan, dayIndex);
  },
  noop() {},
  togglePlanEdit() { this.setData({ editingPlan: !this.data.editingPlan }); },
  editAttraction(event: Event) {
    const dayIndex = Number(event.currentTarget.dataset.day);
    const index = Number(event.currentTarget.dataset.index);
    const field = String(event.currentTarget.dataset.field);
    const value = String(event.detail.value);
    this.setData({ [`plan.days[${dayIndex}].attractions[${index}].${field}`]: field === 'visit_duration' || field === 'ticket_price' ? Number(value) : value });
  },
  deleteAttraction(event: Event) {
    const dayIndex = Number(event.currentTarget.dataset.day);
    const index = Number(event.currentTarget.dataset.index);
    const plan = this.data.plan;
    if (!plan) return;
    const days = [...plan.days];
    const day = { ...days[dayIndex], attractions: [...days[dayIndex].attractions] };
    day.attractions.splice(index, 1);
    days[dayIndex] = day;
    const updated = { ...plan, days };
    this.setData({ plan: updated, editingPlan: true });
    this.updateMap(updated, dayIndex);
  },
  moveAttraction(event: Event) {
    const dayIndex = Number(event.currentTarget.dataset.day);
    const index = Number(event.currentTarget.dataset.index);
    const next = index + Number(event.currentTarget.dataset.delta);
    const plan = this.data.plan;
    if (!plan) return;
    const days = [...plan.days];
    const day = { ...days[dayIndex], attractions: [...days[dayIndex].attractions] };
    if (next < 0 || next >= day.attractions.length) return;
    [day.attractions[index], day.attractions[next]] = [day.attractions[next], day.attractions[index]];
    days[dayIndex] = day;
    const updated = { ...plan, days };
    this.setData({ plan: updated, editingPlan: true });
    this.updateMap(updated, dayIndex);
  },
  openLocation(event: Event) {
    const day = this.data.plan?.days?.[this.data.dayIndex];
    const points: Point[] = [...(day?.hotel ? [day.hotel] : []), ...(day?.attractions ?? []), ...(day?.meals ?? [])];
    const point = points[Number(event.currentTarget.dataset.index)];
    if (point?.location) void this.openMapLocation(point);
  },
  async openMapLocation(point: Point) {
    try { await authorizePrivacy(); }
    catch (_) { return; }
    if (point.location) wx.openLocation({ latitude: point.location.latitude, longitude: point.location.longitude, name: point.name, address: point.address ?? '' });
  },
  async copyPlan() {
    if (!this.data.plan) return;
    try { await authorizePrivacy(); }
    catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '无法使用剪贴板', icon: 'none' }); return; }
    const text = [
      `${this.data.plan.city} · ${this.data.plan.start_date} 至 ${this.data.plan.end_date}`,
      this.data.plan.overall_suggestions ?? '',
      ...(this.data.plan.days ?? []).map((day: any) => `${day.date}\n${day.description}\n${(day.attractions ?? []).map((point: Point) => `- ${point.name} ${point.address ?? ''}`).join('\n')}`),
    ].join('\n\n');
    wx.setClipboardData({ data: text });
  },
  async exportPlan() {
    if (!this.data.plan) return;
    try { await authorizePrivacy(); }
    catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '无法导出文件', icon: 'none' }); return; }
    const lines = [`${this.data.plan.city} · ${this.data.plan.start_date} 至 ${this.data.plan.end_date}`, this.data.plan.overall_suggestions ?? ''];
    for (const [index, day] of (this.data.plan.days ?? []).entries()) {
      lines.push(`\n第 ${index + 1} 天 · ${day.date}`, day.description ?? '');
      if (day.hotel) lines.push(`住宿：${day.hotel.name} ${day.hotel.address ?? ''}`);
      for (const point of day.attractions ?? []) lines.push(`景点：${point.name} ${point.address ?? ''} ${point.description ?? ''}`);
      for (const meal of day.meals ?? []) lines.push(`餐饮：${meal.name} ${meal.address ?? ''}`);
    }
    const content = lines.join('\n');
    const safeCity = String(this.data.plan.city ?? '行程').replace(/[\\/:*?"<>|]/g, '_');
    const filePath = `${wx.env.USER_DATA_PATH}/旅游计划_${safeCity}_${Date.now()}.txt`;
    wx.getFileSystemManager().writeFile({ filePath, data: content, encoding: 'utf8', success: () => {
      const file: ExportedTrip = { name: `旅游计划_${safeCity}.txt`, path: filePath, createdAt: new Date().toISOString() };
      const savedExports = [file, ...this.data.savedExports];
      wx.setStorageSync(this.exportKey(), savedExports);
      this.setData({ savedExports });
      const shareApi = (wx as unknown as { shareFileMessage?: (options: { filePath: string; fileName: string; success?: () => void; fail?: () => void }) => void }).shareFileMessage;
      if (shareApi && wx.canIUse('shareFileMessage')) {
        shareApi({ filePath, fileName: `旅游计划_${safeCity}.txt`, success: () => wx.showToast({ title: '行程文件已打开分享', icon: 'success' }), fail: () => this.copyPlan() });
      } else {
        wx.setClipboardData({ data: content, success: () => wx.showModal({ title: '行程已复制', content: '当前微信版本不能直接分享文件，行程文本已复制到剪贴板。' }) });
      }
    }, fail: () => wx.showToast({ title: '无法生成行程文件', icon: 'none' }) });
  },
  deleteExport(event: Event) {
    const index = Number(event.currentTarget.dataset.index);
    const file = this.data.savedExports[index];
    wx.getFileSystemManager().unlink({ filePath: file.path, complete: () => {
      const savedExports = this.data.savedExports.filter((_, i) => i !== index);
      wx.setStorageSync(this.exportKey(), savedExports);
      this.setData({ savedExports });
    } });
  },
  onPoiQuery(event: Event) { this.setData({ poiQuery: String(event.detail.value) }); },
  async searchPois() {
    if (!this.data.poiQuery.trim() || !this.data.city.trim()) { wx.showToast({ title: '请先填写地点和目的地城市', icon: 'none' }); return; }
    try {
      const response = await request<{ data: Point[] }>('GET', 'travel/poi/search', undefined, true, { keywords: this.data.poiQuery.trim(), city: this.data.city.trim(), source_role: 'attraction' });
      this.setData({ poiResults: response.data ?? [] });
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '地点搜索失败' }); }
  },
  openPoi(event: Event) {
    const point = this.data.poiResults[Number(event.currentTarget.dataset.index)];
    if (point?.location) void this.openMapLocation(point);
  },
  onRouteField(event: Event) { this.setData({ [String(event.currentTarget.dataset.field)]: String(event.detail.value) }); },
  onRouteType(event: Event) { const routeTypeIndex = Number(event.detail.value); this.setData({ routeTypeIndex, routeType: ['walking', 'driving', 'transit'][routeTypeIndex] }); },
  async calculateRoute() {
    if (!this.data.routeOrigin.trim() || !this.data.routeDestination.trim()) { wx.showToast({ title: '请填写起点和终点', icon: 'none' }); return; }
    try {
      const response = await request<{ data: Record<string, any> }>('POST', 'travel/map/route', { origin_address: this.data.routeOrigin.trim(), destination_address: this.data.routeDestination.trim(), route_type: this.data.routeType });
      this.setData({ routeResult: response.data });
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : '路线规划失败' }); }
  },
  retry() { void this.generate(); },
});
