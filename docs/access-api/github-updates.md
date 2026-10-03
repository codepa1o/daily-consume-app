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

- GitHub 本地登录与公开仓库写入权限检查通过。
- Flutter 静态分析通过，`No issues found`。
- `1.0.2+3` Release APK 构建成功，包名与固定签名保持一致。
- 发布脚本本地检查通过，APK 内嵌更新源与 GitHub 仓库匹配。
- GitHub Release 已公开：`https://github.com/codepa1o/daily-consume-app/releases/tag/v1.0.2%2B3`。
- 匿名读取固定清单成功；完整下载 APK 后，大小 50,985,635 字节、SHA256 `82e12a786669d76d81953010dd4a0891893494f5cc11528d582ad849f6e1371b` 与本地一致。
- Android 模拟器升级流程通过：原安装版为 `1.0.0+1`，先覆盖安装仅用于验证的、带 GitHub 更新支持的临时 `1.0.1+2` 基线，再由应用实际读取 GitHub 清单、下载并校验 APK、引导安装授权并覆盖升级到正式版 `1.0.2+3`。没有通过 adb 直接安装正式版来替代更新流程。
- 升级后系统实际版本为 `versionCode=3 / versionName=1.0.2`；再次打开显示完整的本次更新日志。原体重记录及记录数量保留，现有记录未被编辑。
- 关闭日志后冷启动再次验证：同版本日志不再自动弹出，底部“更新日志 · 1.0.2”入口仍可查看。
- 临时基线未上传 GitHub；生产源文件、local.properties 和默认 APK 均已恢复为正式 `1.0.2+3`，APK SHA256 与公开附件一致。
- 模拟器验证截图和界面记录保存在 `build/github-update-validation/`，该目录被 Git 忽略，不会随安装包或发布清单上传。

## 官方资料

- [最新 Release 附件的固定地址](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- [GitHub Release API](https://docs.github.com/en/rest/releases/releases)
- [GitHub Release Asset API](https://docs.github.com/en/rest/releases/assets)
- [Android PackageInstaller 用户确认](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams)
