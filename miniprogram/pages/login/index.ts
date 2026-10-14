import { acceptPrivacyConsent, hasPrivacyConsent, LoginResponse, loginWithWechat, request, saveSession } from '../../services/api';

type TextInputEvent = { detail: { value: string } };
type CheckboxEvent = { detail: { value: string[] } };

Page({
  data: {
    mode: 'login' as 'login' | 'register',
    username: '',
    password: '',
    nickname: '',
    busy: false,
    error: '',
    consented: hasPrivacyConsent(),
  },

  onUsernameInput(event: TextInputEvent) {
    this.setData({ username: event.detail.value });
  },

  onPasswordInput(event: TextInputEvent) {
    this.setData({ password: event.detail.value });
  },

  onNicknameInput(event: TextInputEvent) {
    this.setData({ nickname: event.detail.value });
  },

  onConsent(event: CheckboxEvent) {
    const consented = event.detail.value.includes('agree');
    this.setData({ consented });
    acceptPrivacyConsent(consented);
  },

  toggleMode() {
    this.setData({
      mode: this.data.mode === 'login' ? 'register' : 'login',
      error: '',
    });
  },

  async submit() {
    if (this.data.busy) return;
    if (!this.data.consented) { wx.showToast({ title: '请先阅读并同意隐私保护指引', icon: 'none' }); return; }
    this.setData({ busy: true, error: '' });
    try {
      const credentials = {
        username: this.data.username.trim(),
        password: this.data.password,
      };
      if (this.data.mode === 'register') {
        await request('POST', 'auth/register', {
          ...credentials,
          nickname: this.data.nickname.trim(),
        }, false);
      }
      const session = await request<LoginResponse>(
        'POST', 'auth/login', credentials, false,
      );
      saveSession(session);
      wx.switchTab({ url: '/pages/home/index' });
    } catch (error) {
      this.setData({
        error: error instanceof Error ? error.message : '登录失败，请重试',
      });
    } finally {
      this.setData({ busy: false });
    }
  },

  async submitWechat() {
    if (this.data.busy) return;
    if (!this.data.consented) { wx.showToast({ title: '请先阅读并同意隐私保护指引', icon: 'none' }); return; }
    this.setData({ busy: true, error: '' });
    try {
      saveSession(await loginWithWechat());
      wx.switchTab({ url: '/pages/home/index' });
    } catch (error) {
      this.setData({
        error: error instanceof Error ? error.message : '微信登录失败，请重试',
      });
    } finally {
      this.setData({ busy: false });
    }
  },
});
