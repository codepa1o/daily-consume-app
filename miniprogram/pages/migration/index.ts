import { getAccount, request } from '../../services/api';
import { authorizePrivacy } from '../../services/privacy';

type ImportPackage = { import_id: string; source_id: string; tables: Record<string, Array<Record<string, unknown>>> };
type TapEvent = { currentTarget: { dataset: Record<string, string> } };
function countsOf(tables: ImportPackage['tables']): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const name of Object.keys(tables)) counts[name] = tables[name].length;
  return counts;
}

Page({
  data: {
    username: getAccount()?.username ?? '', packageData: null as ImportPackage | null,
    counts: [] as Array<{ name: string; count: number }>, total: 0,
    selectedFile: '', loading: false, imported: false, error: '',
  },
  onShow() { this.setData({ username: getAccount()?.username ?? '' }); },
  async chooseFile() {
    try { await authorizePrivacy(); }
    catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '无法使用文件', icon: 'none' }); return; }
    wx.chooseMessageFile({ count: 1, type: 'file', extension: ['json'], success: (result) => {
      const file = result.tempFiles[0];
      if (!file) return;
      if (file.size > 10 * 1024 * 1024) { this.setData({ error: '迁移文件超过 10 MB；请使用旧 App 的账号登录流程导入，或联系维护者进行分批迁移。' }); return; }
      this.setData({ loading: true, error: '', packageData: null, selectedFile: file.name });
      wx.getFileSystemManager().readFile({ filePath: file.path, encoding: 'utf8', success: (read) => {
        try {
          const value = JSON.parse(String(read.data)) as ImportPackage;
          if (!/^[a-f0-9]{64}$/.test(value.import_id) || !/^[a-f0-9]{32}$/.test(value.source_id) || !value.tables || typeof value.tables !== 'object') throw new Error('迁移文件格式无效');
          const counts = Object.entries(countsOf(value.tables)).map(([name, count]) => ({ name, count: Number(count) }));
          this.setData({ packageData: value, counts, total: counts.reduce((sum, item) => sum + item.count, 0), loading: false });
        } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '无法解析迁移文件' }); }
      }, fail: () => this.setData({ loading: false, error: '无法读取所选文件' }) });
    } });
  },
  clearFile() { this.setData({ packageData: null, counts: [], total: 0, selectedFile: '', error: '' }); },
  async importRecords() {
    const data = this.data.packageData;
    if (!data || !this.data.username) return;
    wx.showModal({ title: '导入到当前账号？', content: `将 ${this.data.total} 条记录导入 ${this.data.username}。若同日存在不同记录，服务器会停止并保留原数据。`, success: async (result) => {
      if (!result.confirm) return;
      this.setData({ loading: true, error: '' });
      try {
        const receipt = await request<{ import_id: string; counts: Record<string, number> }>('POST', 'legacy/import', data as unknown as Record<string, unknown>);
        const expected = countsOf(data.tables);
        const sameCounts = Object.keys(expected).length === Object.keys(receipt.counts).length && Object.entries(expected).every(([key, count]) => receipt.counts[key] === count);
        if (receipt.import_id !== data.import_id || !sameCounts) throw new Error('服务器导入核对失败；迁移文件仍保留。');
        this.setData({ loading: false, imported: true, packageData: null });
        wx.showModal({ title: '导入完成', content: `已核对 ${this.data.total} 条记录。源迁移文件未删除，可保留作为备份。`, showCancel: false });
      } catch (error) { this.setData({ loading: false, error: error instanceof Error ? error.message : '导入失败，文件仍保留' }); }
    } });
  },
});
