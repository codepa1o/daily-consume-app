# 浏览器 Web 端

Web 端与 Android 共用 Flutter 页面、业务模型和 FastAPI 接口，代码继续放在本仓库。Flutter 官方支持为已有项目添加 Web target；单独维护第二套前端会重复实现账号、表单、日历和 API 模型。只有以后需要 SEO、服务端渲染，或 Web 产品节奏和交互明显分叉时，再考虑拆独立 Web 项目。

若要把记录保存到已部署服务器的数据库，可选择下面的“远端 API”模式，不需要开放 PostgreSQL 端口或安装本地 PostgreSQL。

## 本地启动

需要 Flutter SDK、Chrome 或 Edge、Python 后端依赖，以及一个本机 PostgreSQL 数据库。请使用本地开发库，避免把开发操作指向含真实数据的数据库。首次准备环境时，在仓库根目录安装依赖：

```powershell
python -m pip install -r server/requirements.lock
flutter pub get
```

先在 PowerShell 终端 A 配置本地连接并启动 API：

```powershell
$env:DATABASE_URL = 'postgresql://daily_consume:本机密码@127.0.0.1:5432/daily_consume'
$env:WEB_ALLOWED_ORIGINS = 'http://localhost:8080,http://127.0.0.1:8080'
python -m alembic -c server/alembic.ini upgrade head
python -m uvicorn app:app --app-dir server --host 127.0.0.1 --port 8091
```

`DATABASE_URL` 环境变量优先于根目录 `.env`。首次启动前需要先创建 PostgreSQL 数据库并安装 `server/requirements.lock` 中的依赖。

再在终端 B 从仓库根目录启动 Web 客户端：

```powershell
flutter run -d chrome --web-port 8080
```

然后打开 `http://127.0.0.1:8080`。也可以将 `chrome` 换成 `edge`。调试 Web 默认请求 `http://127.0.0.1:8091/`；本地 Uvicorn 直接提供 FastAPI 路由，线上 Nginx 才负责去掉 `/api/v1/` 前缀。后端只允许 `WEB_ALLOWED_ORIGINS` 中列出的浏览器来源，未设置时不开放跨域访问。

## 使用远端服务器 API

远端 API 使用应用内置 CA，且当前服务没有开放本地浏览器来源的 CORS 预检。浏览器因此不能直接请求远端 HTTPS API。用本机标准库代理解决浏览器跨域和证书信任问题；代理只监听回环地址，并验证远端证书：

```powershell
python scripts/web_api_proxy.py
```

保持代理终端运行，再执行上一节的 `flutter run -d chrome --web-port 8080`。浏览器仍访问本机 `127.0.0.1:8091`，代理将经验证的请求转发到服务器 `/api/v1/`。登录和业务数据仍由服务器 API 按当前账号处理，不需要在本机配置数据库连接或服务器 root 密码。

## 浏览器行为

- 窗口宽度达到 840 px 后切换为左侧导航栏；1200 px 以上显示完整导航和账户入口，主要内容最大宽度为 1480 px。身体、饮食、健身和健康页面会在空间足够时切换为并排布局，窄窗口沿用底部导航和纵向布局。
- 浏览器用 `?page=body`、`?page=diary`、`?page=workout` 或 `?page=female` 标记当前模块；浏览器前进和后退会同步切换页面。
- Web 端健身打卡使用普通点击；Android 端继续使用长按确认。
- 趋势图可切换近 7 / 30 / 90 天或全部记录，并支持鼠标悬停、点击和聚焦后的左右方向键查看具体数据点。
- 头像和回忆照片通过浏览器文件选择器读取。Web 端不扫描或导入 Android 本机 SQLite 旧记录。
- 番茄钟在页面运行期间正常计时；浏览器端没有 Android 的精确闹钟和锁屏通知。切换到后台或关闭页面时，提醒可能延后或不会保存完成记录。
- Web 不下载或安装 APK。网页更新由部署端发布，用户刷新页面获取新版本。
- 开发环境用 localhost HTTP。线上浏览器必须使用受浏览器信任的 HTTPS 证书；Android 资源中的私有 CA 不会自动加入浏览器信任。线上建议由同一 HTTPS 域名提供 Flutter 静态文件和 `/api/v1/` API，这样无需开放生产 CORS。

## Web 发布

```powershell
flutter build web
```

命令生成 `build/web/`。部署时由 Nginx 等静态服务器提供该目录，并将未知页面路径回退到 `index.html`；保留现有 `/api/v1/` 反向代理。生产站点应配置公开信任的域名证书。默认 Release API 地址为当前站点的 `/api/v1/`。

如果 Windows 报端口 `10013`，用 `netsh int ipv4 show excludedportrange protocol=tcp` 检查系统保留范围，改用未被排除的端口，并同步更新允许的 Web 来源。不要删除 Hyper-V、容器或系统组件管理的排除项。

## 技术边界

Web 请求使用浏览器网络栈，TLS 证书由浏览器校验；Android/iOS 仍通过原生网络客户端信任随 App 打包的 CA。原生客户端的 APK 更新器和 SQLite 导入器通过条件导入排除在 Web 构建之外。浏览器版沿用 `flutter_secure_storage` 的 WebCrypto 实现；其密钥和会话数据按站点来源存储，不会在不同浏览器或电脑间迁移。
