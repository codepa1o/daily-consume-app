# 账号与服务器数据

## 已确定的行为

- 用户名与密码注册登录，无游客入口。用户名 3–32 位，支持中文、字母、数字、下划线、短横线，大小写不区分；密码 8–128 位。
- 身体、饮食消费、健身记录、训练计划与自定义部位全部存 PostgreSQL，读取与变更均按当前会话的用户隔离。
- 底部保留身体、饮食消费、健身，新增“我的”：个人资料、更新日志、切换账号、退出登录。
- 业务需要联网，不写本地 SQLite、不缓存业务数据到磁盘。登录凭证由 Android 安全存储保护，关闭系统备份以避免卸载后恢复旧会话。
- 卸载 App 不删除服务器数据。安装新版请覆盖安装，先完成旧记录导入；卸载旧版会丢失尚未导入的旧 SQLite。

## 服务器

- 地址：`https://47.99.142.117/api/v1/`，Nginx 443 转发到仅监听回环地址的 8091。
- Ubuntu 22.04、PostgreSQL 14，数据库与角色 `daily_consume`。数据库仅监听本机，应用通过 Unix socket 和专用系统用户 `daily-consume` 的 peer 映射连接。
- 后端目录 `/opt/daily-consume`，systemd 服务 `daily-consume.service`；开机启动、失败自动重启。
- 2026-10-04 后端已同步为 1.2.1：原有 10 张表保留，新增 `female_health_settings`、`menstrual_periods`、`female_health_days`，共 13 张表；`users` 新增性别，既有账号默认为未设置。迁移前后原有表的行数和内容指纹一致。
- 2026-10-04 后端进一步升级至 1.3.0，正式接管 Alembic 并升级至 `0003_couple`，共 19 张业务表；日历与情侣空间服务已上线。原 13 张业务表的行数和内容指纹一致，代码和数据库备份保存在服务器 `/var/backups/daily-consume/`；真实 HTTPS 的情侣功能与原业务检查均通过。
- 2026-10-04 后端随 1.3.1 更新迁移至 `0004_avatar`。`users` 新增受约束的头像 `BYTEA` 字段，总业务表数仍为 19；情侣回忆时间线由发布时刻按 Asia/Shanghai 日期分组，不另建时间线记录表。
- 2026-10-04 后端随 1.3.3 部署升级至 `0005_pomodoro`，新增账号专属的番茄钟设置、专注事项和完成记录表，共 22 张业务表。部署前数据库备份为 `/var/backups/daily-consume/daily_consume-pre-1.3.3-20261004T104935Z.dump`，`pg_restore --list` 检查通过；迁移完成后 API health 与新路由鉴权检查通过。
- 2026-10-05 后端随 1.3.4+11 部署升级至 `0006_memory_albums`，新增有序相册照片表并回填旧单图回忆，当前共 23 张业务表。部署前数据库备份 `/var/backups/daily-consume/daily_consume-pre-1.3.4-20261004T195407Z.dump`（SHA256 `7a866d4e3d5d71f0077947660a59750ae820682b9b008b0ae45d30e2ab8839b9`）及代码备份 `/var/backups/daily-consume/daily-consume-code-pre-1.3.4-20261004T195407Z.tar.gz` 均已留存，数据库备份经 `pg_restore --list` 检查。修复发布接口后，服务与 Nginx 为 active，Alembic head、健康检查及 7 组真实 HTTPS 情侣空间检查通过；报告在 `/opt/daily-consume/couple-api-checks.json`，本次随机账号已清理。
- 用户密码使用 Argon2 哈希，会话使用随机 Bearer 凭证，数据库只保存其 SHA256。会话有效期 30 天，过期重新登录，退出立即撤销当前会话。
- HTTPS 使用带 IP SAN 的专用证书，客户端仅信任 APK 内的 `assets/server_ca.pem`；仍校验服务器地址和有效期，没有跳过 TLS 检查。当前证书有效期至 2029-10-02；轮换前需要先为客户端发布兼容的新证书。
- 登录/注册按来源 IP 限流。服务端拒绝客户端提交用户 ID 等未定义字段，业务查询从会话确定归属。
- SSH 密码仅从临时环境变量读取，不在代码、APK、文档或日志中保存。

## 接口

认证与资料接口：`POST auth/register`（username、password、nickname）、`POST auth/login`（username、password）、`GET me`、`PUT me`（nickname、gender）、`PUT me/avatar`（photo_base64）、`POST auth/logout`。女性健康接口与实际部署验证见 `docs/access-api/female-health.md`。

业务请求携带 `Authorization: Bearer <session>`；未登录/过期为 401，账号或数据冲突为 409，输入错误为 422，限流为 429。所有接口响应为 JSON，关闭缓存。

| 路径 | 方法 | 输入/返回 |
|---|---|---|
| weights | GET / PUT | 返回日期与 grams；保存 date、grams |
| heights | GET / PUT | 返回日期与 millimeters；保存 date、millimeters |
| meals | GET / PUT / DELETE | 查询 start/end；保存 date、meal_type、foods、expense_cents；删除 date/meal_type |
| workout/muscles | GET / POST / PUT / DELETE | 查询部位；新增或改色 name/color_value；删除 name，仅允许自定义部位 |
| workout/settings | GET | 返回 weekly_goal |
| workout/plans | GET | 返回 weekday、muscles、is_rest |
| workout/schedule | PUT | weekly_goal 与完整的七天 plans，事务保存 |
| workout/logs | GET / POST / DELETE | 查询 start/end；当天打卡 date/muscles；删除 date；禁止休息日和重复打卡 |
| pomodoro/settings | GET / PUT | 读取或保存账号的专注、短休息、长休息时长和长休息轮数 |
| pomodoro/tasks | GET / POST / DELETE | 读取、添加或按 id 删除当前账号的专注事项；标题忽略大小写去重 |
| pomodoro/sessions | GET / POST | 按日期查询已完成专注；提交记录时校验所属任务并按 client_request_id 去重 |
| legacy/import | POST | source_id、import_id、tables；返回导入凭据和逐表 counts |

## 旧记录导入

SQLite 仅作为只读的旧数据来源保留，不再新建或升级本地业务数据库。新版登录后展示当前用户名，明确确认归属后才提交；也可暂缓，在“我的”继续。

每份导入使用安全保存的安装来源 ID 与原始数据摘要生成 import_id。服务器校验摘要，逐表验证并在单个事务中导入、核对，生成凭据。相同来源重试不重复插入，已导入其他账号则拒绝。相同日期/餐次有不同内容时整体回滚，不覆盖任意一侧的数据。

客户端核对凭据、每张表的数量、当前账号和原本机快照后，才删除旧数据库。重复请求还会核对服务器数据是否已变更。任何冲突、网络错误或检查失败都会保留本机文件。

## 部署与检查

`scripts/server_admin.py` 使用 Paramiko，通过 `DAILY_SSH_PASSWORD`、可选的 `DAILY_SSH_USER` 和 `DAILY_SSH_HOST` 连接；服务端不使用 SSH 密码连接数据库。主机密钥保存在电脑用户目录 `.ssh/daily-consume-known-hosts`，后续变更会被拒绝。

初次运行 `server/bootstrap.sh` 创建数据库、专用用户和 TLS 证书。上传 app.py、journal.py、couple.py、database.py、alembic.ini、完整 migrations/ 目录、requirements.txt、requirements.lock、deploy.sh、daily-consume.service、nginx.conf 后运行 `server/deploy.sh`。脚本以应用系统用户执行 Alembic 迁移，成功后才重启服务；首次接管已有数据库会核对基线 13 张表的结构，不一致则中止，再执行增量迁移。不要重新生成已有服务器私钥。操作说明见 [数据库迁移指南](../database-migrations.md)、[生活日历说明](journal.md) 和 [情侣空间说明](couple-space.md)。

真实接口检查（服务器上，以应用用户运行）：

```sh
runuser -u daily-consume -- /opt/daily-consume/venv/bin/python /opt/daily-consume/check_api.py --connect-host 127.0.0.1 --ca /opt/daily-consume/server_ca.pem --cleanup --report /opt/daily-consume/api-checks.json
```

该命令经过实际 Nginx HTTPS、实际后端和 PostgreSQL；连接回环地址时仍验证证书中的服务器 IP。使用随机测试账号，结束后仅删除本次生成的账号。报告不包含密码或凭证。

数据库备份可由管理员执行 `runuser -u postgres -- pg_dump -Fc daily_consume > /受保护的备份目录/daily_consume.dump`，备份应保存在服务器之外并验证可恢复。

实现参考官方文档：[FastAPI](https://fastapi.tiangolo.com/tutorial/security/first-steps/)、[Psycopg](https://www.psycopg.org/psycopg3/docs/basic/usage.html)、[Argon2](https://argon2-cffi.readthedocs.io/en/stable/howto.html)、[Flutter Secure Storage](https://pub.dev/packages/flutter_secure_storage)。
