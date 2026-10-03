# 日常 · 身体、饮食消费与健身记录

Android 优先的 Flutter 应用，使用用户名和密码注册登录。身体、饮食消费及健身记录保存在服务器 PostgreSQL 中，必须登录并联网使用，各账号的数据独立。

## 当前实现

- 身体页：记录身高与每日体重，展示当前身高、最近体重和体重趋势折线图。
- 饮食页：按日期记录早餐、午餐、晚餐的餐食内容与消费金额。
- 消费统计：按日、周、月汇总餐费，并展示各餐次消费。
- 健身页：训练部位多选、自定义部位及颜色、每周目标和训练计划；长按 2 秒打卡，展示小红花奖励，并支持撤销。
- 健身统计：周一至周日概览，以及日、周、月统计和月历；休息日禁用打卡，历史记录保留原部位和颜色。
- 女性健康：个人资料保存为女生后显示，默认隐藏；支持经期开始/结束、历史补录、实际出血日期调整、每日经量/痛经/症状/心情/备注、彩色月历、经期和易孕窗口估计、周期历史及趋势。预测和实际记录分开，支持暂停预测和独立删除健康数据。
- 服务器数据：体重以克、身高以毫米、金额以分保存；同一天、同一餐次可编辑。App 不再写入本地业务数据库。
- 我的：展示用户名、昵称、性别、注册时间，可编辑昵称及性别，支持退出登录与切换账号。卸载 App 后服务器数据保留，重新登录可恢复。
- 旧记录导入：登录后明确确认本机旧记录属于当前账号，服务器原子导入并核对完整后才清理旧 SQLite；冲突、网络失败或核对失败均保留旧文件。
- 软件更新：每次冷启动检查一次 GitHub Releases，有新版本自动下载；展示进度，校验大小和 SHA256 后交给 Android 安装。
- 更新日志：APK 自带本次更新内容，新版本首次打开时弹出一次；查看入口统一位于“我的”，各业务栏底部不再展示。

## App 图标

桌面图标与身体、饮食、健身页面的品牌标识统一使用蕾姆 Q 版头像。
原始透明 PNG：`assets/branding/rem_logo.png`；预览页面：`design/rem-logo-preview.html`。
Android 图标由 `flutter_launcher_icons.yaml` 生成，适配多种分辨率与自适应图标形状。
更新原始图片后执行 `dart run flutter_launcher_icons`，然后重新构建安装包。

## 运行

女性健康接口与数据库变更需要与客户端一起部署；服务启动时自动执行可重复的数据库迁移，旧账号性别为“未设置”。实现与验证见 `docs/access-api/female-health.md`。

本机 Flutter SDK：E:\JAVAstudy\flutter_windows_3.47.5-stable\flutter

本机 Android SDK：E:\Android\Sdk

从项目根目录运行：

    flutter pub get
    flutter run

构建本地安装用 APK：

    flutter build apk --release

APK 默认输出到 build/app/outputs/flutter-apk/app-release.apk。

此工程已包含 Android 平台脚手架。若 Android Studio 的全局 SDK Location 仍指向其他目录，可在 SDK Manager 中将其改为 E:\Android\Sdk；Flutter 构建使用项目 android/local.properties 中的 SDK 路径。

## 更新与发布

目前版本为 `1.2.1+6`。自 `1.0.2+3` 起，更新源使用 GitHub Releases；早于该版本的安装包需要先手动覆盖安装新版，之后才可以从 GitHub 获取更新。覆盖安装保留旧 SQLite，待确认归属并成功导入账号后再清理；业务记录需要联网。更新检查失败不会影响已连接的业务服务。

本次新增女性健康与个人资料编辑，需要同步部署本版后端接口；客户端发版不会自动更新业务服务器。完整的构建、发布与网页操作教程见 [GitHub Release 发布教程](docs/github-release-guide.md)。

默认更新地址：

    https://github.com/codepa1o/daily-consume-app/releases/latest/download/latest.json

APK 与 `latest.json` 都作为公开 GitHub Release 的附件发布，无需自有域名或服务器。应用匿名下载；GitHub 上传凭证仅在电脑端使用。下载支持最多 5 次 HTTPS 跳转，只接受配置域名及 GitHub 指定的下载域名。网络检查与日志展示独立进行，安装在应用前台继续。

Android 首次更新可能要求允许本应用“安装未知应用”；点击“允许安装更新”，授权后返回即可继续。系统要求确认安装时需点击确认；如果取消，可以在更新面板重试。成功更新后再次打开应用即可看到更新日志，关闭后同一版本不再自动弹出。

### 1. 构建新版本

将本次更新内容写到一个 UTF-8 文本文件，例如 `release-notes.txt`，每行一条。执行：

```powershell
.\scripts\build_release.ps1 -VersionName '1.1.1' -VersionCode 5 -NotesFile '.\release-notes.txt'
```

若当前终端找不到 Flutter，可以增加参数：

```powershell
-Flutter 'E:\JAVAstudy\flutter_windows_3.47.5-stable\flutter\bin\flutter.bat'
```

脚本同步更新 `pubspec.yaml` 与 `assets/release_notes.json`（含更新源地址），然后构建 APK。`VersionCode` 必须递增。重建当前版本直接执行 `flutter build apk --release`。如使用其他公开发布仓库，构建和发布两个脚本都传入对应的 `OWNER/REPO`：构建参数为 `-Repository`，发布参数为 `--repo`。

### 2. 配置发布环境

GitHub 发布脚本只依赖 Python 标准库，以及 Android Build-Tools 中的 aapt/apksigner。它依次使用本地 `GH_TOKEN` / `GITHUB_TOKEN`、`gh auth login` 登录状态、或 Git 凭证管理器的既有登录。凭证需要目标仓库的 Contents 写入权限；不会写入应用、清单或日志。发布仓库必须公开且可写。

只读检查访问与本地检查 APK：

```powershell
python scripts/publish_github_release.py --check-access
python scripts/publish_github_release.py --dry-run
```

`--dry-run` 不联网、不上传。它读取 APK 中的实际包名、版本、更新源与更新日志，并用 `apksigner` 验证签名；版本、日志或发布仓库不一致会中止。

### 3. 发布到 GitHub Releases

```powershell
python scripts/publish_github_release.py
```

默认读取 `build/app/outputs/flutter-apk/app-release.apk`，也可用 `--apk` 指定其他 APK。脚本按以下顺序发布：

1. 检查公开仓库权限和已发布版本，拒绝版本倒退、更换签名或不匹配的更新源。
2. 创建或复用对应版本的草稿 Release，例如 `v1.1.1+5`。
3. 上传 `app-release.apk` 与 `latest.json`，核对 GitHub 返回的大小和 SHA256。
4. 两个附件完整后公开 Release，并将它设为最新正式版本。
5. 匿名读取固定清单地址，下载 APK 并核对大小与 SHA256。

网络中断时可再次运行，复用完全一致的附件；不会删除或覆盖不同内容的已发布附件。上传失败时草稿保留，旧版继续作为最新版本。每次只运行一个发布进程。正式发布后若匿名检查失败，应查看具体错误并重试检查，不要删除仍在使用的正式版本。

Manifest 包含 `packageName`、`versionName`、`versionCode`、`apkUrl`、`size`、`sha256`、`signingCertificateSha256`、`releaseNotes`、`publishedAt`。APK 地址固定到具体版本；清单通过 `releases/latest/download/latest.json` 获取，启动请求添加时间参数避免旧缓存。应用还会核对实际包名、版本和签名。

### 签名与数据保留

为兼容之前已安装的 APK，本机已将原调试签名密钥保存为 `android/keys/daily-consume.jks`，构建通过 `android/key.properties` 使用这份固定密钥。两个文件均被 Git 忽略；请私下备份，换电脑时恢复相同密钥。当前密钥来源于原调试签名，适合现有个人使用场景；不要换签名后尝试覆盖更新，也不要卸载旧版，否则原数据可能丢失。

首次在其他电脑构建时，需要恢复 `android/key.properties` 和密钥；缺少签名配置不会自动切换成另一份签名。

实现与检查记录见 `docs/access-api/github-updates.md`。

## 原 OSS 发布方案

`scripts/publish_release.py` 作为原 OSS 方案保留，不是当前应用的默认更新源。`1.0.1+2` APK 已在 OSS 并通过鉴权下载校验，但默认 OSS 域名公开下载 APK 返回 `ApkDownloadForbidden`，版本清单未发布。恢复该方案需要可用的 HTTPS 自定义下载域名，并同步配置应用更新地址；详细记录见 `docs/access-api/oss-updates.md`。
