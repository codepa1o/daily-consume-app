import { MINI_PROGRAM_RELEASE_NOTES, MINI_PROGRAM_VERSION } from './config';

App({
  onLaunch() {
    const manager = wx.getUpdateManager();
    manager.onUpdateReady(() => {
      wx.showModal({
        title: '版本更新',
        content: '小程序新版本已准备好，重启后立即使用。',
        confirmText: '立即更新',
        cancelText: '稍后',
        success: (result) => { if (result.confirm) manager.applyUpdate(); },
      });
    });
    manager.onUpdateFailed(() => {
      wx.showToast({ title: '版本下载失败，请稍后重新打开', icon: 'none' });
    });
    const seenKey = `daily_consume_release_${MINI_PROGRAM_VERSION}`;
    if (!wx.getStorageSync<boolean>(seenKey)) {
      wx.setStorageSync(seenKey, true);
      setTimeout(() => wx.showModal({
        title: `日常 ${MINI_PROGRAM_VERSION}`,
        content: MINI_PROGRAM_RELEASE_NOTES.join('\n'),
        showCancel: false,
      }), 500);
    }
  },
});
