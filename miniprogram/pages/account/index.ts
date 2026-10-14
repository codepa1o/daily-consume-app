import { Account, bindWechat, clearSession, getAccount, getToken, hasPrivacyConsent, request, saveAccount, WechatStatus } from '../../services/api';
import { authorizePrivacy } from '../../services/privacy';

type InputEvent = { detail: { value: string } };
type PickerEvent = { detail: { value: string } };
type AccountDetails = Account & { avatar_base64: string | null };

Page({
  data: {
    nickname: '',
    username: '',
    createdAt: '',
    avatarText: '日',
    avatarPath: '',
    gender: 'unset',
    ageInput: '',
    savingProfile: false,
    genderOptions: ['未设置', '男', '女'],
    wechatConfigured: false,
    wechatBound: false,
    wechatLoading: false,
  },

  onShow() {
    if (getToken() && !hasPrivacyConsent()) { wx.redirectTo({ url: '/pages/login/index' }); return; }
    const account = getAccount();
    this.setData({
      nickname: account?.nickname || '',
      username: account?.username || '',
      createdAt: account?.created_at?.slice(0, 10) || '',
      avatarText: account?.nickname.slice(0, 1) || '日',
      gender: account?.gender || 'unset',
      ageInput: account?.age == null ? '' : String(account.age),
    });
    if (getToken()) {
      void this.loadProfile();
      void this.loadWechatStatus();
    }
  },

  async loadProfile() {
    try {
      const account = await request<AccountDetails>('GET', 'me');
      saveAccount(account);
      let avatarPath = '';
      if (account.avatar_base64) {
        avatarPath = `${wx.env.USER_DATA_PATH}/avatar-${account.id}.jpg`;
        try { wx.getFileSystemManager().writeFileSync(avatarPath, wx.base64ToArrayBuffer(account.avatar_base64)); }
        catch (_) { avatarPath = ''; }
      }
      this.setData({
        nickname: account.nickname,
        username: account.username,
        createdAt: account.created_at.slice(0, 10),
        avatarText: account.nickname.slice(0, 1) || '日',
        avatarPath,
        gender: account.gender,
        ageInput: account.age == null ? '' : String(account.age),
      });
    } catch (_) {}
  },

  onNickname(event: InputEvent) { this.setData({ nickname: event.detail.value }); },
  onAge(event: InputEvent) { this.setData({ ageInput: event.detail.value }); },
  onGender(event: PickerEvent) { this.setData({ gender: ['unset', 'male', 'female'][Number(event.detail.value)] }); },

  async saveProfile() {
    const nickname = this.data.nickname.trim();
    const ageText = this.data.ageInput.trim();
    const age = ageText ? Number(ageText) : null;
    if (!nickname || nickname.length > 32 || (age !== null && (!Number.isInteger(age) || age < 1 || age > 120))) {
      wx.showToast({ title: '请检查昵称或年龄', icon: 'none' });
      return;
    }
    this.setData({ savingProfile: true });
    try {
      const account = await request<Account>('PUT', 'me', { nickname, gender: this.data.gender, age });
      saveAccount(account);
      this.setData({ nickname: account.nickname, gender: account.gender, ageInput: account.age == null ? '' : String(account.age), avatarText: account.nickname.slice(0, 1) });
      wx.showToast({ title: '资料已保存', icon: 'success' });
    } catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '保存失败', icon: 'none' }); }
    finally { this.setData({ savingProfile: false }); }
  },

  async chooseAvatar() {
    try { await authorizePrivacy(); }
    catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '无法使用照片', icon: 'none' }); return; }
    wx.chooseMedia({ count: 1, mediaType: ['image'], sizeType: ['compressed'], sourceType: ['album', 'camera'], success: (result) => {
      const file = result.tempFiles[0];
      if (!file) return;
      if (file.size > 8 * 1024 * 1024) { wx.showToast({ title: '图片不能超过 8 MB', icon: 'none' }); return; }
      wx.cropImage({ src: file.tempFilePath, cropScale: '1:1', success: (cropped) => {
        wx.getFileSystemManager().readFile({ filePath: cropped.tempFilePath, encoding: 'base64', success: async (read) => {
          this.setData({ avatarPath: cropped.tempFilePath });
          try {
            const account = await request<AccountDetails>('PUT', 'me/avatar', { photo_base64: String(read.data) });
            saveAccount(account);
            this.setData({ avatarText: account.nickname.slice(0, 1) || '日' });
            wx.showToast({ title: '头像已更新', icon: 'success' });
          } catch (error) { wx.showToast({ title: error instanceof Error ? error.message : '头像上传失败', icon: 'none' }); }
        }, fail: () => wx.showToast({ title: '无法读取裁剪后的图片', icon: 'none' }) });
      }, fail: () => wx.showToast({ title: '已取消头像裁剪', icon: 'none' }) });
    } });
  },

  async loadWechatStatus() {
    try {
      const status = await request<WechatStatus>('GET', 'auth/wechat/status');
      this.setData({ wechatConfigured: status.configured, wechatBound: status.bound });
    } catch (_) {}
  },

  async bindWechat() {
    this.setData({ wechatLoading: true });
    try {
      await bindWechat();
      this.setData({ wechatBound: true });
      wx.showToast({ title: '绑定成功', icon: 'success' });
    } catch (error) {
      wx.showModal({
        title: '绑定失败',
        content: error instanceof Error ? error.message : '请稍后重试',
        showCancel: false,
      });
    } finally {
      this.setData({ wechatLoading: false });
    }
  },

  goLogin() {
    wx.navigateTo({ url: '/pages/login/index' });
  },
  openMigration() { wx.navigateTo({ url: '/pages/migration/index' }); },
  openReleases() { wx.navigateTo({ url: '/pages/releases/index' }); },
  openPrivacy() { wx.navigateTo({ url: '/pages/privacy/index' }); },

  async signOut() {
    try {
      if (getToken()) await request('POST', 'auth/logout');
    } catch (_) {
      // 网络不可用时仍允许清除本机登录状态。
    }
    clearSession();
    wx.redirectTo({ url: '/pages/login/index' });
  },
});
