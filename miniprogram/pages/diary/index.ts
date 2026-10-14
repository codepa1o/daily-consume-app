import { ApiError, HttpMethod, request } from '../../services/api';
import { dateKey, dateRange, money, shiftDate } from '../../services/dates';

const mealTypes = ['早餐', '午餐', '晚餐'];
type MealItem = { key: string; name: string; amount: string };
type Meal = { meal_type: string; items: MealItem[]; saved: boolean };
type SavedMeal = { date: string; meal_type: string; foods: string; expense_cents: number; items?: Array<{ name: string; expense_cents: number }> };
type Expense = { id: number; date: string; category: string; expense_cents: number; amount: string };
type InputEvent = { detail: { value: string } };
type DatasetEvent = { currentTarget: { dataset: Record<string, string> }; detail: { value: string } };
let itemSequence = 0;
const newMealItem = (name = '', amount = '') => ({ key: `meal-${++itemSequence}`, name, amount });

Page({
  data: {
    today: dateKey(),
    date: dateKey(),
    period: 'day' as 'day' | 'week' | 'month',
    meals: mealTypes.map((meal_type) => ({ meal_type, items: [newMealItem()], saved: false })) as Meal[],
    expenses: [] as Expense[],
    periodStats: { breakfast: '0.00', lunch: '0.00', dinner: '0.00', meals: '0.00', other: '0.00', total: '0.00' },
    newCategory: '',
    newAmount: '',
    loading: false,
    saving: false,
    error: '',
  },

  onShow() { void this.load(); },

  async load() {
    const range = dateRange(this.data.date, this.data.period);
    this.setData({ loading: true, error: '' });
    try {
      const [allMeals, allExpenses] = await Promise.all([
        request<SavedMeal[]>('GET', 'meals', undefined, true, { start: range.start, end: range.end }),
        request<Array<Omit<Expense, 'amount'>>>('GET', 'other-expenses', undefined, true, { start: range.start, end: range.end }),
      ]);
      const todayMeals = allMeals.filter((row) => row.date === this.data.date);
      const meals = mealTypes.map((meal_type) => {
        const row = todayMeals.find((item) => item.meal_type === meal_type);
        const items = row?.items?.length
          ? row.items.map((item) => newMealItem(item.name, money(item.expense_cents)))
          : row ? [newMealItem(row.foods, money(row.expense_cents))] : [newMealItem()];
        return { meal_type, items, saved: row != null };
      });
      const dayExpenses = allExpenses.filter((row) => row.date === this.data.date)
        .map((row) => ({ ...row, amount: money(row.expense_cents) }));
      const totals = { breakfast: 0, lunch: 0, dinner: 0 };
      for (const row of allMeals) {
        const key = row.meal_type === '早餐' ? 'breakfast' : row.meal_type === '午餐' ? 'lunch' : 'dinner';
        totals[key] += row.expense_cents;
      }
      const mealTotal = totals.breakfast + totals.lunch + totals.dinner;
      const otherTotal = allExpenses.reduce((sum, item) => sum + item.expense_cents, 0);
      this.setData({
        meals,
        expenses: dayExpenses,
        periodStats: {
          breakfast: money(totals.breakfast), lunch: money(totals.lunch), dinner: money(totals.dinner),
          meals: money(mealTotal), other: money(otherTotal), total: money(mealTotal + otherTotal),
        },
        loading: false,
      });
    } catch (error) {
      this.setData({ loading: false, error: error instanceof ApiError ? error.message : '加载失败，请重试' });
    }
  },

  onDateChange(event: InputEvent) {
    const date = event.detail.value;
    if (date > this.data.today) return;
    this.setData({ date });
    void this.load();
  },

  onPeriodTap(event: DatasetEvent) {
    this.setData({ period: event.currentTarget.dataset.period as 'day' | 'week' | 'month' });
    void this.load();
  },

  previousDate() { this.setData({ date: shiftDate(this.data.date, -1) }); void this.load(); },
  nextDate() {
    const next = shiftDate(this.data.date, 1);
    if (next <= this.data.today) { this.setData({ date: next }); void this.load(); }
  },

  onMealName(event: DatasetEvent) {
    const { mealIndex, itemIndex } = event.currentTarget.dataset;
    this.setData({ [`meals[${mealIndex}].items[${itemIndex}].name`]: event.detail.value });
  },
  onMealAmount(event: DatasetEvent) {
    const { mealIndex, itemIndex } = event.currentTarget.dataset;
    this.setData({ [`meals[${mealIndex}].items[${itemIndex}].amount`]: event.detail.value });
  },
  addMealItem(event: DatasetEvent) {
    const index = Number(event.currentTarget.dataset.mealIndex);
    const meals = this.data.meals.map((meal, i) => i === index ? { ...meal, items: [...meal.items, newMealItem()] } : meal);
    this.setData({ meals });
  },
  removeMealItem(event: DatasetEvent) {
    const mealIndex = Number(event.currentTarget.dataset.mealIndex);
    const itemIndex = Number(event.currentTarget.dataset.itemIndex);
    const meals = this.data.meals.map((meal, i) => i === mealIndex && meal.items.length > 1
      ? { ...meal, items: meal.items.filter((_, j) => j !== itemIndex) }
      : meal);
    this.setData({ meals });
  },

  async saveMeal(event: DatasetEvent) {
    const meal = this.data.meals[Number(event.currentTarget.dataset.mealIndex)];
    const items = meal.items.map((item) => ({ name: item.name.trim(), expense_cents: Math.round(Number(item.amount || 0) * 100) }));
    if (items.some((item) => !item.name || !Number.isFinite(item.expense_cents) || item.expense_cents < 0)) {
      wx.showToast({ title: '请填写餐食名称和有效金额', icon: 'none' });
      return;
    }
    const expense_cents = items.reduce((sum, item) => sum + item.expense_cents, 0);
    await this.save('PUT', 'meals', {
      date: this.data.date,
      meal_type: meal.meal_type,
      foods: items.map((item) => item.name).join('、'),
      expense_cents,
      items,
    }, `${meal.meal_type}已保存`);
  },

  async deleteMeal(event: DatasetEvent) {
    const meal = this.data.meals[Number(event.currentTarget.dataset.mealIndex)];
    if (!meal.saved) return;
    const result = await wx.showModal({ title: `删除${meal.meal_type}记录？`, content: '餐食和消费明细都会删除。' });
    if (!result.confirm) return;
    await this.save('DELETE', 'meals', undefined, `${meal.meal_type}已删除`, { date: this.data.date, meal_type: meal.meal_type });
  },

  onNewCategory(event: InputEvent) { this.setData({ newCategory: event.detail.value }); },
  onNewAmount(event: InputEvent) { this.setData({ newAmount: event.detail.value }); },
  onExpenseCategory(event: DatasetEvent) {
    const index = Number(event.currentTarget.dataset.index);
    this.setData({ [`expenses[${index}].category`]: event.detail.value });
  },
  onExpenseAmount(event: DatasetEvent) {
    const index = Number(event.currentTarget.dataset.index);
    this.setData({ [`expenses[${index}].amount`]: event.detail.value });
  },
  onExpenseDate(event: DatasetEvent) {
    const index = Number(event.currentTarget.dataset.index);
    this.setData({ [`expenses[${index}].date`]: event.detail.value });
  },

  async addExpense() {
    if (!this.data.newCategory.trim() || !this.data.newAmount.trim() || !Number.isFinite(Number(this.data.newAmount)) || Number(this.data.newAmount) < 0) {
      wx.showToast({ title: '请填写类别和有效金额', icon: 'none' });
      return;
    }
    await this.save('POST', 'other-expenses', {
      date: this.data.date,
      category: this.data.newCategory.trim(),
      expense_cents: Math.round(Number(this.data.newAmount) * 100),
    }, '消费已保存');
    if (!this.data.error) this.setData({ newCategory: '', newAmount: '' });
  },

  async saveExpense(event: DatasetEvent) {
    const row = this.data.expenses[Number(event.currentTarget.dataset.index)];
    if (!row.category.trim() || !row.amount.trim() || !Number.isFinite(Number(row.amount)) || Number(row.amount) < 0) {
      wx.showToast({ title: '请填写类别和有效金额', icon: 'none' });
      return;
    }
    await this.save('PUT', `other-expenses/${row.id}`, {
      date: row.date,
      category: row.category.trim(),
      expense_cents: Math.round(Number(row.amount) * 100),
    }, '消费已更新');
  },

  async deleteExpense(event: DatasetEvent) {
    const row = this.data.expenses[Number(event.currentTarget.dataset.index)];
    const result = await wx.showModal({ title: '删除这笔消费？', content: `将删除“${row.category}”记录。` });
    if (result.confirm) await this.save('DELETE', `other-expenses/${row.id}`, undefined, '消费已删除');
  },

  async save(method: HttpMethod, path: string, body?: Record<string, unknown>, success = '已保存', query?: Record<string, string>) {
    if ((method === 'POST' || method === 'PUT') && path.includes('other-expenses') &&
        (!String(body?.category || '').trim() || !Number.isFinite(Number(body?.expense_cents)) || Number(body?.expense_cents) < 0)) {
      wx.showToast({ title: '请填写类别和有效金额', icon: 'none' });
      return;
    }
    this.setData({ saving: true, error: '' });
    try {
      await request(method, path, body, true, query);
      wx.showToast({ title: success, icon: 'success' });
      await this.load();
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : '保存失败，请重试' });
    } finally {
      this.setData({ saving: false });
    }
  },

  retry() { void this.load(); },
});
