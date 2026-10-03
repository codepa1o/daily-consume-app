# 如何把更新包发布到 GitHub Release

适用于本项目 `codepa1o/daily-consume-app`。更新包放在 GitHub Release 附件中，不要把 APK、签名密钥或登录令牌提交到 Git 仓库。

## 本次版本

- 应用显示版本：1.2.1。
- 内部版本编号：6，即 `pubspec.yaml` 中的 `1.2.1+6`。
- Release 标签：`v1.2.1+6`。
- 更新日志原稿：`docs/release-notes/1.2.1.txt`，每行一条。
- 女性健康需要同步部署本版 `server/app.py` 和 `server/schema.sql`；GitHub 发布 APK 不会自动部署后端。

## 以后发布新版的推荐步骤

以下以 **下一版 1.2.2+7** 为例。不要再次用这个步骤创建已发布的 1.2.1+6。

### 1. 验证代码

在项目根目录打开 PowerShell：

```powershell
Set-Location E:\my_project\daily-consume
& 'E:\JAVAstudy\flutter_windows_3.47.5-stable\flutter\bin\flutter.bat' analyze
& 'E:\JAVAstudy\flutter_windows_3.47.5-stable\flutter\bin\flutter.bat' test
```

涉及服务器功能时，先部署并验证兼容的新后端，再公开更新包。发布脚本本身只管理 GitHub Release，不会更新业务服务器。

### 2. 写日志并构建

新建 UTF-8 文件 `docs/release-notes/1.2.2.txt`，每行一条给用户看的更新内容，然后执行：

```powershell
.\scripts\build_release.ps1 `
  -VersionName '1.2.2' `
  -VersionCode 7 `
  -NotesFile '.\docs\release-notes\1.2.2.txt' `
  -Flutter 'E:\JAVAstudy\flutter_windows_3.47.5-stable\flutter\bin\flutter.bat'
```

脚本同步更新 `pubspec.yaml` 和 APK 内置的 `assets/release_notes.json`，并生成 `build/app/outputs/flutter-apk/app-release.apk`。

`VersionName` 是用户看到的版本，`VersionCode` 是应用比较新旧的编号，每次正式发布必须增加。构建脚本只允许增加编号；如果版本已写入但构建中断，修复后重新构建当前版本：

```powershell
& 'E:\JAVAstudy\flutter_windows_3.47.5-stable\flutter\bin\flutter.bat' build apk --release
```

保留本机 `android/key.properties` 与原签名密钥，不能更换签名，否则旧用户不能覆盖安装。它们保持在 Git 忽略列表中。

### 3. 提交并合并

把版本、日志和功能代码提交到功能分支，推送并通过 Pull Request 合并到 `main`。发布脚本默认给 Release 绑定远程默认分支，所以先合并，再发布，确保标签对应本次更新代码。

### 4. 检查权限和安装包

```powershell
python scripts/publish_github_release.py --check-access
python scripts/publish_github_release.py --dry-run
```

第一条只检查 GitHub 登录与仓库写权限；第二条只检查本地 APK 的包名、版本、内置日志、签名、大小和 SHA256，不上传文件。

脚本优先使用本机 `GH_TOKEN` / `GITHUB_TOKEN`，其次已登录的 GitHub CLI，再使用已有 Git 凭据管理器登录。本项目已可使用现有 GitHub 凭据，无需每次重新登录。如果都没有，可安装 GitHub CLI 后执行 `gh auth login`，或在本机安全设置具有本仓库 Contents 写权限的令牌；不要把令牌写入代码、日志或聊天。

### 5. 发布

```powershell
python scripts/publish_github_release.py
```

脚本会：

1. 从 APK 读取实际版本，创建或复用对应标签的草稿 Release。
2. 上传 `app-release.apk` 和自动生成的 `latest.json`，核对大小和 SHA256。
3. 两个附件完整后公开 Release，并标记为 Latest。
4. 匿名读取固定更新清单、下载 APK，核对真实下载内容。

成功后终端会显示 Release、Manifest 和 APK 地址。网络中断后可重试相同发布命令；相同附件会复用，不同内容不会被覆盖。一次只运行一个发布进程；正式发布后还要修改 APK 时，应增加 `VersionCode`，不要覆盖旧附件。

生成的清单位于 `build/github-release/<VersionCode>/latest.json`，本次为 `build/github-release/6/latest.json`，无需手工编写。

## 网页手动发布

脚本更适合本项目，因为自动更新还需要版本清单。网页流程是：

1. 打开仓库的 [Releases](https://github.com/codepa1o/daily-consume-app/releases)，点击 **Draft a new release**。
2. 选择本版标签（如 `v1.2.1+6`）；创建新标签时 Target 选择已合并本版代码的 `main`。
3. 填写标题和更新日志，保持为草稿。
4. 在附件区域上传本版 `app-release.apk` 和经校验生成的 `latest.json`。清单内 APK 地址必须对应本版标签，大小、SHA256 和签名信息必须对应本版 APK。
5. 两个文件上传完成后，取消 Pre-release，勾选 **Set as latest release** 并发布。

参考 [GitHub 官方发布说明](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)。只上传 APK 可以手动下载，但 App 自动更新还需要 `latest.json`。

## 发布后检查

- [最新 Release](https://github.com/codepa1o/daily-consume-app/releases/latest) 显示新版本。
- [固定清单](https://github.com/codepa1o/daily-consume-app/releases/latest/download/latest.json) 中版本和编号正确。
- 用旧版 App 冷启动检查更新，下载完成后确认覆盖安装；首次可能需要允许“安装未知应用”。
- 覆盖安装后确认登录、原记录及更新日志；本次女性健康在资料设为女生后才出现。

脚本验证通过证明公开附件可下载；设备安装和真实业务功能仍需在后端部署后实际验收。
