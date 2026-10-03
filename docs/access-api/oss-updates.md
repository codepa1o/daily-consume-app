# OSS 软件更新接入

## 接口与凭证

- Bucket：`daily-consume-app`
- Region：`cn-beijing`
- 上传 Endpoint：`https://oss-cn-beijing.aliyuncs.com`
- 下载 Origin：`https://daily-consume-app.oss-cn-beijing.aliyuncs.com`
- 应用端：匿名 HTTPS GET 版本清单与 APK，没有上传凭证。
- 发布端：阿里云 OSS Python SDK V2 1.4.0，签名 V4；从环境变量读取 `OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`、可选 `OSS_SESSION_TOKEN`。
- `1.0.1+2` APK 已存在于 OSS，实际鉴权下载后的大小和 SHA256 与本地 APK 一致。版本清单尚未发布，公开下载受默认 OSS 域名分发 APK 的限制影响。
- 当前尚无已绑定的用户自定义域名。截图中的 `daily-consume-app.cn-beijing.taihangcda.cn` 是阿里云提供的 CNAME 指向目标，不是用户自有域名。应绑定自己已注册的下载域名，并配置 DNS 和匹配的 HTTPS 证书后继续发布。

## 文件和功能

| 文件 | 功能 |
|---|---|
| `lib/update/app_updates.dart` | 冷启动检查、下载进度、大小/SHA256 校验、授权和重试界面、离线日志 |
| `android/app/src/main/kotlin/com/example/daily_consume/MainActivity.kt` | 读取安装版本，安装授权，APK 实际包名/版本/签名核对，PackageInstaller Session |
| `android/app/src/main/kotlin/com/example/daily_consume/UpdateInstallReceiver.kt` | 安装状态回调、系统确认界面、失败提示 |
| `assets/release_notes.json` | 随 APK 分发的当前版本日志 |
| `scripts/build_release.ps1` | 同步版本与日志并构建 APK |
| `scripts/publish_release.py` | APK 检查、上传、匿名下载回验、最后发布 latest.json |

## 启动与更新规则

每次应用冷启动只检查一次；切换页面、从后台返回不重复查询。新版日志首次显示后记下版本号，之后可通过日志入口主动查看。更新日志随 APK 分发，不依赖更新完成后再访问 OSS。

更新下载和校验不阻塞本地记录。未发布、离线、超时或清单格式不正确时继续使用当前版本。有新版本时自动下载，显示进度；失败可重试。取消安装后保留已校验安装包，下次可复用。成功更新后启动会清理旧版 APK 缓存。

清单限制为 64 KiB，APK 为 512 MiB，版本号必须大于设备实际版本，下载地址必须是配置清单同一 HTTPS 域名。禁止跳转下载。应用端同时校验文件大小、SHA256、APK 实际包名/版本和签名；操作系统完成最终安装验证。

Android 12 及以上尝试平台支持的无需用户操作的自更新；系统要求确认时显示安装确认界面。首次更新通常还需要“安装未知应用”授权。更新成功后再次打开应用显示本次日志。取消、下载失败、安装失败均保留原应用和个人数据库。

## 发布规则

1. 从实际 APK 读取包名、版本、内嵌更新日志，用 Android Build-Tools 的 apksigner 验证签名。
2. 拒绝旧版本、同版本覆盖以及与上次发布签名不同的 APK。
3. 上传版本目录下 APK，设置其 public-read、不可覆盖和长期缓存。
4. 通过 HEAD 与匿名 GET 验证对象元数据、实际下载大小与 SHA256。
5. 在上传前限制最终 JSON 为 64 KiB；再核对远端版本未改变，最后写入 no-store 的 latest.json，并匿名读取确认。

上传 APK 成功但后续验证失败时，旧版本清单保持原样；相同内容可重新运行脚本继续发布。每次只运行一个发布进程。发布只公开发布目录里的 APK 和清单，不更改整个 Bucket 的访问控制。

## 本次检查记录

- Flutter Android Release APK 已成功编译，实际版本 `1.0.1+2`。
- Flutter 静态分析通过：`No issues found`。
- Python 发布脚本与 PowerShell 构建脚本语法检查通过。
- `publish_release.py --dry-run`：本地 APK 包名、实际版本、签名、大小、SHA256 和内嵌中文日志检查通过。
- `publish_release.py --check-access`：真实 OSS 鉴权读取通过，返回 `NoSuchKey`，当前尚无 latest.json。
- 匿名访问版本清单返回 HTTP 404，与未发布状态一致。
- 已执行正式发布命令：发现相同 APK 已在 OSS，复用该对象；默认域名下载校验失败，错误 `ApkDownloadForbidden`，没有发布 latest.json。
- 实际鉴权下载 APK 返回 HTTP 200，大小 50,985,455 字节，SHA256 与本地一致。
- 发布脚本已修正版本目录中 `+` 的 URL 编码为 `%2B`，并增加最终 JSON 大小预检。
- HTTPS 自定义域名配置、匿名下载及手机安装授权/覆盖升级完整流程尚未完成。
- 对截图中的服务商域名申请 CNAME 验证返回 `InvalidCname: The cname is not allowed`；该域名不能作为用户自有域名绑定。阿里云官方说明明确将 taihang 系列地址作为 DNS 的 CNAME 记录值。

## 使用说明与官方资料

具体命令见项目根目录 README.md。

- [阿里云 OSS Python SDK V2](https://www.alibabacloud.com/help/en/oss/developer-reference/2-0-manual-preview-version/)
- [SDK V2 文件上传](https://www.alibabacloud.com/help/en/oss/developer-reference/simple-upload-using-oss-sdk-for-python-v2)
- [OSS PutObject 与缓存头](https://www.alibabacloud.com/help/en/oss/developer-reference/putobject)
- [默认 OSS 域名禁止分发 APK：0048-00000200](https://www.alibabacloud.com/help/en/oss/user-guide/48-00000200)
- [用户自定义域名绑定与 CNAME 指向目标的区别](https://www.alibabacloud.com/help/en/oss/user-guide/access-buckets-via-custom-domain-names)
- [Android PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller)
- [Android 安装会话与用户确认](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams)
- [Android 应用签名](https://developer.android.com/studio/publish/app-signing)
