export function dateKey(value = new Date()): string {
  const year = value.getFullYear().toString().padStart(4, '0');
  const month = (value.getMonth() + 1).toString().padStart(2, '0');
  const day = value.getDate().toString().padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function parseDate(key: string): Date {
  const [year, month, day] = key.split('-').map(Number);
  return new Date(year, month - 1, day);
}

export function shiftDate(key: string, days: number): string {
  const date = parseDate(key);
  date.setDate(date.getDate() + days);
  return dateKey(date);
}

export function dateRange(key: string, period: 'day' | 'week' | 'month') {
  if (period === 'day') return { start: key, end: key };
  const date = parseDate(key);
  if (period === 'week') {
    const monday = shiftDate(key, -((date.getDay() + 6) % 7));
    return { start: monday, end: shiftDate(monday, 6) };
  }
  const start = `${key.slice(0, 7)}-01`;
  const last = new Date(date.getFullYear(), date.getMonth() + 1, 0);
  return { start, end: dateKey(last) };
}

export function money(cents: number): string {
  return (cents / 100).toFixed(2);
}
