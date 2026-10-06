# AGENTS.md

## 技术栈

- Android 客户端：Flutter、Dart，使用 Material 3。
- 服务端：Python、FastAPI、PostgreSQL；数据库结构由 Alembic 迁移管理。
- 客户端与服务端通过 HTTP API 通信；密钥和部署配置通过环境变量提供。

## 目录结构

- `lib/`：Flutter 应用入口、页面、数据访问、共享组件和更新功能。
- `test/`：Flutter 测试。
- `server/`：FastAPI 服务、数据库配置、Alembic 迁移和服务端测试。
- `android/`：Android 平台工程及构建配置。
- `assets/`：应用图片、品牌素材和版本说明。
- `design/`：界面原型、设计说明和视觉素材。
- `docs/`：接口接入、迁移、实现和发布文档。
- `scripts/`：构建、发布和管理脚本。

## 编码规范

- 先沿用现有目录划分、命名方式和组件/API 模式，保持修改聚焦。
- Dart 代码使用 `dart format` 格式化，并以 `flutter analyze` 检查。
- Python 代码遵循现有模块结构与风格；变更服务端行为时更新相应测试。
- 数据库结构变更必须新增 Alembic 迁移；应用启动时不得自行修改数据库结构。
- 代码注释使用简体中文；协议名、标识符和必要的原文术语保留原样。
- 不把密钥、签名文件或本机配置写入代码或提交到 Git。

## 构建与检查命令

在仓库根目录运行 Flutter 命令：

```sh
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk --release
```

服务端测试从仓库根目录运行；需要数据库的用例应按测试说明配置隔离的 `TEST_DATABASE_URL`：

```sh
python -m unittest discover -s server -p 'test_*.py' -v
```

服务端安装依赖：

```sh
python -m pip install -r server/requirements.txt
```

## Git 永不规则

- 新增功能或接口时，**永不新建分支或工作树**；始终在当前已检出的分支上实现。
- **永不使用 `git stash`，永不切换分支**；不得通过 `git checkout`、`git switch` 等命令离开当前分支。
