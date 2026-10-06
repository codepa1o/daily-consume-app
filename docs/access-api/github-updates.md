# GitHub Releases 软件更新接入

## 发布与下载

- 公开发布仓库：`codepa1o/daily-consume-app`。
- 固定清单地址：`https://github.com/codepa1o/daily-consume-app/releases/latest/download/latest.json`。
- 初次迁移版本：`1.0.2+3`，原 OSS 版本需先手动覆盖安装此版。
- APK 下载地址固定到具体版本 tag；清单与 APK 均为 GitHub Release 附件。
- 应用端匿名 HTTPS 下载，不需要域名、服务器或 GitHub Token。
- 发布端使用 GitHub REST API，上传凭证只从电脑端既有登录或环境变量读取，不写入应用或发布文件。

## 接口

| 操作 | 请求 |
|---|---|
| 读取仓库和权限 | `GET https://api.github.com/repos/{owner}/{repo}` |
| 查询版本与草稿 | `GET https://api.github.com/repos/{owner}/{repo}/releases` |
| 创建草稿 | `POST https://api.github.com/repos/{owner}/{repo}/releases` |
| 上传附件 | `POST https://uploads.github.com/repos/{owner}/{repo}/releases/{id}/assets?name=...` |
| 公开发布 | `PATCH https://api.github.com/repos/{owner}/{repo}/releases/{id}` |

安装完成后，PackageInstaller 回调由专用的 `UpdateCompletionActivity` 接收。收到成功状态时，它清除临时遮罩并带回主页面；需要系统确认时，先启动 Android 安装确认界面。回调使用按安装会话 ID 创建的、不可导出的 Activity PendingIntent；API 34 及以上显式授予这个自更新回调后台启动 App 的权限。

API 版本：`2026-03-10`。发布凭证需要目标仓库 Contents 写入权限。移动端不调用这些写入接口。

## 应用实现

`lib/update/app_updates.dart` 每次冷启动只检查一次；检查与首次更新日志弹窗独立执行。HTTPS 下载最多跟随 5 次跳转，跳转仅允许配置的更新域名与 GitHub 的 `release-assets.githubusercontent.com`、`objects.githubusercontent.com`、`github-releases.githubusercontent.com`。

清单仍限制为 64 KiB，APK 限制为 512 MiB；校验版本号、大小和 SHA256。安装前 Android 原生代码核对 APK 实际包名、版本和签名。APK 校验完成后，应用在前台、日志弹窗关闭时继续安装；未授权时引导“安装未知应用”设置。取消安装后可复用校验通过的缓存。

更新日志随 APK 保存，升级后首次打开显示一次，之后可以通过底部入口离线查看。本地 SQLite 文件与表结构未改变。

## 发布脚本

`scripts/publish_github_release.py` 复用原 APK 检查逻辑，只依赖 Python 标准库与 Android Build-Tools。它会核对 APK 的版本、签名和内嵌更新源是否与发布仓库一致。

执行顺序：创建或复用草稿 → 上传 APK 和清单 → 核对 GitHub 返回的文件大小与 SHA256 → 两个附件齐全后公开 Release 并标记 latest → 匿名读取稳定清单地址并下载 APK 校验。

相同内容的草稿附件可复用；不同内容或已经公开但不完整的附件会拒绝覆盖。失败时保留草稿供继续发布；每次只运行一个发布进程。实际发布命令和后续版本构建命令见 README.md。

## 检查记录

- GitHub 本地登录和 Release 仓库权限检查通过。
- Flutter 静态分析通过，`No issues found`；APK 签名、版本及更新源校验通过。
- Release `v1.3.7+14` 已公开。GitHub 匿名清单与 APK下载SHA256校验通过。
- 安装成功回调会将更新清单ActivityIntent直接路由到透明 Activity，成功后Activity会打开MainActivity，pendingUserAction会显示确认界面。
- 当前连接的Android模拟器处于 `offline`，故安装完成后的自动重启仍未进行设备实测。

旧版本 `1.0.2+3` 的模拟器升级测试记录见以下历史条目；该测试没有验证 `1.3.7+14` 新增的安装后自动重启逻辑。

## 官方资料

- [最新 Release 附件的固定地址](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- [GitHub Release API](https://docs.github.com/en/rest/releases/releases)
- [GitHub Release Asset API](https://docs.github.com/en/rest/releases/assets)
- [Android PackageInstaller 用户确认](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams)
