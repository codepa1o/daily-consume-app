export function authorizePrivacy(): Promise<void> {
  if (!wx.requirePrivacyAuthorize) return Promise.resolve();
  return new Promise((resolve, reject) => {
    wx.requirePrivacyAuthorize({
      success: () => resolve(),
      fail: () => reject(new Error('请先阅读并同意隐私保护指引，再使用此功能。')),
    });
  });
}
