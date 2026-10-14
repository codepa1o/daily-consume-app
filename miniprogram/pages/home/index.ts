import { Account, ApiError, clearSession, getAccount, getToken, hasPrivacyConsent, request, saveAccount } from '../../services/api';

Page({
  data: {
    nickname: '',
    loading: true,
    error: '',
    female: false,
  },

  onShow() {
    if (!hasPrivacyConsent() || !getToken()) {
      wx.redirectTo({ url: '/pages/login/index' });
      return;
    }
    const account = getAccount();
    this.setData({ female: account?.gender === 'female' });
    void this.restoreAccount();
  },

  async restoreAccount() {
    this.setData({ loading: true, error: '' });
    try {
      const account = await request<Account>('GET', 'me');
      saveAccount(account);
      this.setData({ nickname: account.nickname, female: account.gender === 'female', loading: false });
    } catch (error) {
      if (!getToken()) {
        clearSession();
        wx.redirectTo({ url: '/pages/login/index' });
        return;
      }
      this.setData({
        loading: false,
        error: error instanceof ApiError ? error.message : '加载失败，请重试',
      });
    }
  },

  retry() {
    void this.restoreAccount();
  },

  openBody() { wx.navigateTo({ url: '/pages/body/index' }); },
  openDiary() { wx.navigateTo({ url: '/pages/diary/index' }); },
  openWorkout() { wx.navigateTo({ url: '/pages/workout/index' }); },
  openJournal() { wx.navigateTo({ url: '/pages/journal/index' }); },
  openHealth() { wx.navigateTo({ url: '/pages/health/index' }); },
  openFocus() { wx.navigateTo({ url: '/pages/focus/index' }); },
  openChatbot() { wx.navigateTo({ url: '/pages/chatbot/index' }); },
  openAi() { wx.navigateTo({ url: '/pages/ai/index' }); },
  openResearch() { wx.navigateTo({ url: '/pages/research/index' }); },
  openSkills() { wx.navigateTo({ url: '/pages/skills/index' }); },
  openCouple() { wx.navigateTo({ url: '/pages/couple/index' }); },
  openTravel() { wx.navigateTo({ url: '/pages/travel/index' }); },
});
