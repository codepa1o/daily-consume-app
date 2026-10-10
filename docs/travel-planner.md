# 旅游规划功能

## 功能范围

- Flutter 新增“旅游规划”导航栏，支持城市、日期、同行人数、预算、交通、住宿、偏好和额外要求。
- 使用源项目的行程规划器、POI 搜索与价格估算逻辑，生成按天的景点、餐饮、酒店、天气和预算安排。
- 展示全程/每日高德地图，支持景点信息、行程调整、Android 系统分享图片/PDF 和 Web 下载。
- 规划 API 复用日常 App 的登录认证。生成结果只保留在当前 App 会话中，和源项目的 sessionStorage 行为一致。

## 服务端配置

把以下配置写入部署环境或仓库根目录 `.env`；实际密钥不要提交到 Git：

```dotenv
AMAP_API_KEY=高德 Web 服务 Key
DEEPSEEK_API_KEY=现有 DeepSeek API Key
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-flash
UNSPLASH_ACCESS_KEY=可选，景点照片查询
```

旅行规划默认沿用现有 `DEEPSEEK_*` 配置，也可以设置 `LLM_API_KEY`、`LLM_BASE_URL`、`LLM_MODEL_ID` 单独覆盖。个性化规划模型使用 `USE_PERSONALIZED_PLANNER`、`PERSONALIZED_LLM_API_KEY`、`PERSONALIZED_LLM_BASE_URL` 和 `PERSONALIZED_LLM_MODEL_ID`。

Python 服务依赖已列入 `server/requirements.txt`。部署时继续按原流程安装该文件；不需要数据库迁移。

## 客户端地图配置

地图使用高德 JavaScript API。分别为 Web 域名及 Android 应用配置受限的 JavaScript Key，并在构建时注入：

```powershell
flutter build apk --release --dart-define=AMAP_WEB_JS_KEY=你的高德JSKey
flutter build web --release --dart-define=AMAP_WEB_JS_KEY=你的高德JSKey
```

如高德控制台为该 Key 配置了安全密钥，再通过 `--dart-define=AMAP_WEB_JS_SECURITY_CODE=...` 注入。客户端构建产物中的 JS Key 可被提取，必须在高德控制台限制可用域名或应用；`AMAP_API_KEY` 保留在服务端，不能作为客户端地图 Key 使用。

## API 与请求时限

路由位于现有 `/api/v1/` 下，包括 `/travel/plan`、`/travel/poi/search`、`/travel/poi/detail/{poi_id}`、`/travel/poi/photo`、`/travel/map/poi`、`/travel/map/weather` 和 `/travel/map/route`。所有旅游 API 都需要日常 App 登录。

规划请求最多等待 10 分 30 秒；`server/nginx.conf` 的读取/发送超时已调整到 11 分钟，以容纳源规划器的慢请求和重试。
