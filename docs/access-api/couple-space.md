# 情侣空间

Flutter 客户端和 FastAPI/PostgreSQL 后端实现。入口：我的 → 情侣空间。

当前公开版本为 `1.3.4+11`，服务器数据库已升级至 Alembic `0006_memory_albums`。真实 HTTPS 检查已通过纪念日同步、双图滑动、九图九宫格、照片顺序、上限及越权检查；Android 真机相册体验仍需人工验收。

## 使用流程

创建空间时设置名字和在一起的日期；之后双方都可以从空间首页的纪念日卡片打开日历，修改恋爱纪念日。卡片以衬线字体显示在一起多久，并同时显示包含开始当天的累计天数。创建者生成 12 位邀请码，7 天内有效，生成新码替换旧码；另一人输入后先看到邀请者、空间名字和日期，确认双方共享范围后加入。每个账号只有一个空间，每个空间最多两人。加入后不能邀请第三人。

空间成员可以一次添加最多 9 张照片，选择九宫格或左右滑动的卡片相册展示；也可以发布纯文字回忆，并设置回忆日期、标题、正文和心情。详情中可以查看完整九宫格或横向滑动浏览大图。双方可以查看、留言、用“❤️、抱抱、想你、开心”回应。只能删除自己的回忆；删除同时移除其照片、留言和表情，客户端先确认。

回忆册和星空可切换，分页查看历史。回忆册按服务器发布时间（Asia/Shanghai）倒序显示纵向时间线，一天只有一个日期节点；同一天发布的照片、文字和心情都归入这个节点。历史补录仍留在实际发布日，若所选回忆日期不同，在卡片标注“回忆于 YYYY-MM-DD”。翻页遇到同一天剩余内容时，合并到现有节点，不重复显示日期。下拉、刷新按钮和回到前台时获取最新数据。首版未提供实时推送、解除绑定、照片原文件下载和离线持久草稿。个人日历、身体及女性健康数据仍按个人账号隔离，不会因绑定分享。

## 照片玩法

- 拍立得显影：相纸覆盖逐渐消失，可再次播放。
- 翻面留言：翻面展示作者记录和最新留言，下方可查看全部留言。
- 双人拼贴：使用同一日期、每位作者最新的一张照片；不足两人照片时显示等待提示，不复制同一张照片填充。
- 惊喜刮刮卡：拖动擦除涂层，提供直接打开和重新盖上操作。
- 回忆星空：每颗星对应真实回忆，可以点开；多页星空和列表共用已加载记录。
- 立体照片：手指控制卡片透视和光影，松手归位。这是立体卡片视差，尚未生成照片深度图或重建人像前后景。

## 回忆时间线

回忆册按 `created_at` 发布时刻分日；API 使用 `(created_at AT TIME ZONE 'Asia/Shanghai')::date` 返回 `published_date`。列表按发布时间与 ID 倒序，最近一天在顶部。同一天的一张或多张回忆显示在同一个日期节点下；offset 分页可以穿过某一天，客户端按 `published_date` 合并已加载的记录，不能重复绘制日期节点。

回忆编辑器里的 `memory_date` 表示照片中事情发生的日期，不参与时间线分组。回忆补录到今天发布时，显示在今天的节点，照片下方显示“回忆于 YYYY-MM-DD”。双人拼贴也按发布日取双方最新的照片，与选填的发生日期无关。

## 存储与访问

客户端一次最多选择 9 张相册图片，缩至最长边 1600 像素、质量 85；每张服务端限制 8 MB，单条回忆合计限制 12 MB，图片最多 2400 万像素。服务端接收静态 JPG/PNG/WebP，完整解码、校正朝向后生成最长边 1600/400 的 JPEG 浏览图和缩略图。重新编码移除 EXIF/GPS 等附加信息，不保存原文件。九宫格封面由服务端生成；滑动模式按照片顺序展示。

当前两人私用场景使用 PostgreSQL BYTEA 保存照片，与记录一起备份；大量相册时再迁移至对象存储。所有读取通过现有 Bearer 会话鉴权，照片没有公开 URL，响应为 `no-store`。第三个账号即使知道回忆 ID 也不能读取照片或记录。

保存回忆与留言携带 32 位 `client_request_id`，重复且相同的请求返回原记录，内容不同的重复请求返回 409；失败保留编辑内容。App 启动回收 Android 被系统中断的照片选择结果（最多保留 9 张），用户确认后才能继续编辑，不自动上传。未保存编辑返回前确认放弃。

## 接口

所有路径相对 `/api/v1/`，由会话确定用户及共享空间，拒绝提交用户 ID 等未定义字段。

| 路径 | 方法 | 行为 |
| --- | --- | --- |
| couple/space | GET / POST | 获取当前空间（未绑定为 null）；创建空间 title、since_date |
| couple/space/anniversary | PUT | 更新双方共享的恋爱纪念日 since_date，使用日历日期 |
| couple/invite | POST | 生成新邀请码及有效期 |
| couple/invite/preview | POST | code，查看邀请，不建立成员关系 |
| couple/join | POST | code，确认加入，消费邀请码 |
| couple/memories | GET / POST | 按发布时间倒序分页；每条记录返回上海时区 `published_date`、`photo_count`、`display_mode`；保存 `memory_date`、title、content、mood、最多 9 张 `photos_base64`、`display_mode`（`grid` 或 `swipe`）、client_request_id；保留旧客户端 `photo_base64` |
| couple/pair | GET | date 是发布时间的上海日历日期；返回当天每位成员最新的一张照片 |
| couple/memories/{id} | GET / DELETE | 详情含留言和表情；作者删除 |
| couple/memories/{id}/photo | GET | thumbnail=true/false，返回鉴权后的 JPEG |
| couple/memories/{id}/photos | GET | 按顺序返回这条相册的缩略图 |
| couple/memories/{id}/photos/{position} | GET | 返回 0–8 位置的鉴权 JPEG；thumbnail=true/false |
| couple/memories/{id}/comments | POST | content、client_request_id |
| couple/memories/{id}/reaction | PUT | emoji，null 清除自己的表情 |

## 部署与验证

升级至 Alembic `0006_memory_albums`（依赖 `0005_pomodoro`）；上传 couple.py、journal.py、database.py、app.py、迁移目录和依赖文件，Pillow 纳入依赖锁。按数据库迁移指南先备份，再执行 deploy.sh。API 安装包使用现有服务器地址和证书。

真实 PostgreSQL 检查：设置 `TEST_DATABASE_URL` 指向隔离测试库，运行 `python -m unittest discover -s server -p 'test_*.py' -v`。用例覆盖邀请码失效/并发抢占、第三人访问、图片验证/缩放/元数据清理、重试去重、表情覆盖、作者删除、发布时间分组与分页拼贴，以及已有表数据保留。

上线后从服务器实际 Nginx HTTPS 检查：

```sh
cd /opt/daily-consume
runuser -u daily-consume -- ./venv/bin/python check_couple_api.py \
  --connect-host 127.0.0.1 --ca /opt/daily-consume/server_ca.pem \
  --report /opt/daily-consume/couple-api-checks.json
```

脚本创建随机测试账号，经过真实证书校验、Nginx、API 和 PostgreSQL；最终仅删除本次创建的空间和账号。报告不含密码、邀请码或会话凭证。

Flutter 检查：`flutter analyze`、`flutter test`、`flutter build apk --release`。界面用例覆盖显影/翻面/刮刮卡/星空交互、320 像素大字体六种玩法、失败保留输入和成功重试返回、纯文字记录不请求照片，以及首页到详情导航。

## 本次验证结果

- 本地真实 PostgreSQL：全部 29 项后端/迁移测试通过，使用独立实例和随机 schema，结束后停止测试实例。
- Flutter：分析无问题，全部 47 项测试通过；六种玩法已用 320 像素宽、1.6 倍文字验证，并渲染检查界面。
- 服务器：先保存代码和数据库备份 `/var/backups/daily-consume/couple-before-20261004-032810.*`，pg_restore 列表检查成功。迁移接管前后原 13 张业务表的行数和内容 SHA256 一致；新增日历与情侣表未改变既有记录。
- 真实 Nginx HTTPS：情侣空间 5 组检查及原有业务 11 组检查通过，随机验证账号和空间已清理。报告见 [情侣空间检查](couple-api-checks.json)，原业务结果保存于服务器 `/opt/daily-consume/api-checks.json`。
- 本机公网 HTTPS 健康检查返回 200/ok，TLS 继续使用现有证书。
- APK：包名 `com.example.daily_consume`，版本 `1.3.0+8`，57,200,201 字节；SHA256 `ee3882b345633ce14683adf9a32a6e91d2fd37b9dfbfb1249a60ecbb4aef97c1`；既有签名核对通过。

Windows 上项目位于 E 盘、pub 缓存位于 C 盘，Kotlin 增量路径映射无法处理跨盘插件源文件。Android 构建配置关闭 Kotlin 增量编译并使用进程内编译，修复相册插件构建；会增加重新编译成本。配置依据见 [Kotlin 编译与缓存文档](https://kotlinlang.org/docs/gradle-compilation-and-caches.html)。
