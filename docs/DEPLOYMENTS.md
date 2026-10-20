# 服务器部署记录

按部署日期从新到旧记录版本、代码、迁移、备份和验收结果，也记录只更新后端的部署。本文于 2026-10-14 根据仓库现有资料整理；已归档的最新部署是 **1.4.9+24（2026-10-20）**，各项状态均为当次检查结果。

记录来源：[账号与服务器历史说明](access-api/account-server.md)、[账号功能验证记录](access-api/account-validation.md) 及 [各版本部署 JSON](release-notes/)。原资料未记录的提交、完成时刻或备份路径标记为“未记录”。备份文件名中的 `Z` 表示 UTC，不能据此推定部署完成时刻。

版本功能变更见 [CHANGELOG.md](../CHANGELOG.md)，数据库操作流程见 [迁移指南](database-migrations.md)，APK 发布流程见 [GitHub Release 指南](github-release-guide.md)。

## 环境信息

| 项目 | 已记录配置 |
| --- | --- |
| API 地址 | `https://47.99.142.117/api/v1/` |
| 后端目录 | `/opt/daily-consume` |
| 服务 | `daily-consume.service`，Nginx 443 转发至回环地址 8091 |
| 数据库 | PostgreSQL 14，数据库与角色 `daily_consume` |
| 应用系统用户 | `daily-consume`，默认通过 Unix socket 与 peer 映射连接数据库 |
| 环境文件 | `/opt/daily-consume/.env`，由 systemd 注入 |
| 备份目录 | `/var/backups/daily-consume/` |

以下内容记录历史部署，不代表已重新查询当前服务器。新迁移文件和客户端版本号不能单独作为上线成功的依据。

## 2026-10-20 · 1.4.9+24 · Android HTTPS 信任修复

- **原因**：Nginx 使用自动续期的 Let’s Encrypt IP 证书后，旧版 Android 仅信任旧自签名证书，因 CA 不匹配无法连接 API。服务和数据库均运行正常。
- **变更**：APK 在原自签名锚点外加入 ISRG Root X1/X2，仍严格验证 IP SAN、证书链和有效期；未改动 Nginx、服务端程序和数据库。
- **验收**：新 CA bundle 对当前 Let’s Encrypt 证书链和旧自签名证书均通过验证；在生产 Nginx 本机 HTTPS health 返回 200。签名 APK 构建、版本及 SHA256 核对通过；Android 客户端文件静态分析通过，全量分析有 5 条既有提示；本轮未运行测试或设备安装。
- **详细记录**：[1.4.9 客户端 TLS 验收](release-notes/1.4.9-client-tls.json)。

## 2026-10-17 · 1.4.8+23 · 收入记录与收支统计

- **代码依据**：Release 标签 `v1.4.8+23`；源文件清单 SHA256 `6d1c85d2f98f2c3c947e4cbc792fc4780344c0d4a1c00acf783fcb999f5db30e`。
- **数据库**：从 `0017_couple_comment_interactions` 升级至 `0018_income_entries`；新增收入表、整数分金额、备注与创建请求唯一约束。
- **数据保留**：45 张既有表行数不变；56 条餐食、10 条其他消费完整内容 SHA256 一致，6 条历史评论及原始时间保持完整。
- **备份**：`/var/backups/daily-consume/daily-consume-pre-1.4.8-20261017T155944Z`，含数据库、代码和 Nginx 配置；`pg_restore --list` 检查通过。
- **验收**：签名 APK 1.4.8+23 构建通过、原签名一致；修改文件静态分析与 Python 语法检查通过。服务、Nginx 为 active，公网固定 CA 的 HTTPS health 正常，新收入接口要求登录；本轮未运行单元测试或设备安装验收。
- **回滚**：恢复备份代码并重启，保留新收入表；存在收入记录时拒绝有损删表回退。数据库恢复须评估备份后的新记录。
- **详细记录**：[1.4.8-deployment.json](release-notes/1.4.8-deployment.json)。

## 2026-10-16 · 1.4.7+22 · 评论互动与历史时间

- **代码依据**：Release 标签 `v1.4.7+22`；源文件清单 SHA256 `38241f7eb2677b5ae05b98212552ea24b5ea48058e43a6d5edee404547760710`。
- **数据库**：`0016_pomodoro_reminders` 升级至 `0017_couple_comment_interactions`，新增两种评论的回复关联及唯一点赞表；43 张既有表行数不变。
- **历史评论**：5 条回忆评论、0 条反思评论。已有评论的完整内容和原始时间 SHA256 均前后一致；无缺失时间。新版客户端按原始发布时间显示北京时间，精确到秒。
- **备份**：`/var/backups/daily-consume/daily-consume-pre-1.4.7-20261016T145204Z`，含数据库、代码与 Nginx 配置；数据库归档列表和备份 SHA256 校验通过。
- **验收**：开发阶段 40 项隔离数据库检查及 21 项 Flutter 相关检查通过；本次修改文件静态分析无问题，签名 APK 构建通过。全仓静态分析有 5 条其他代码的既有提示。服务和 Nginx 为 active，固定 CA 的公网 health 为 200/ok，两种评论读取接口要求认证。
- **部署过程**：首次迁移完成后，验收脚本误访问已禁用的 OpenAPI HTTP 端点，自动恢复旧代码；迁移与历史数据保留。改为读取应用路由定义后重新部署并验收成功，复用原始备份。
- **回滚**：恢复代码后重启，保留新增表列；有回复或点赞时迁移会拒绝有损降级。数据库恢复须评估备份后的新记录。
- **详细记录**：[1.4.7-deployment.json](release-notes/1.4.7-deployment.json)。

## 2026-10-15 · 1.4.6+21 · 视觉对齐与微信接口

- **代码依据**：Release 标签 `v1.4.6+21`；源文件清单 SHA256 为 `4bef924b3cc4c6ba1d4221c4efc82eccd533237aee316aa03f4295b8ee6b6453`。
- **数据库**：从 `0014_chatbot` 升级至 `0016_pomodoro_reminders`，新增微信身份、番茄钟提醒表；现有业务表行数保持一致。
- **备份**：`/var/backups/daily-consume/daily-consume-pre-1.4.6-20261014T164731Z`，含 `database.dump`、`code.tar.gz` 和 `nginx.conf`；数据库归档通过 `pg_restore --list`。
- **校验**：数据库 SHA256 `e075fb163574145fb2d2f1e3b59d80262f09a5cb973c03a8f5a1cfb607c159e3`；代码 SHA256 `7a61ae8f3138b36852d4fbfcbef0476649f975683b0b65b31387d7c0e0d1ed9e`。
- **验收**：38 项隔离数据库后端检查通过；服务与 Nginx 为 active；8 组 HTTPS 业务检查通过，新增路由的认证与未配置状态符合预期，本机固定 CA 公网 HTTPS health 返回 200。
- **配置**：本次保留服务器环境与 TLS 文件；微信 AppSecret 和订阅模板未配置，这两项可选能力暂未启用。Nginx 为微信认证路由增加与登录相同的限流。
- **回滚**：恢复备份代码和 Nginx 配置后重启；两条迁移为新增表，旧版本可保留新表运行。需要恢复数据库时使用配套归档，并评估备份之后的新记录；不直接删表回退。
- **详细记录**：[1.4.6-deployment.json](release-notes/1.4.6-deployment.json)。

## 2026-10-12 · 1.4.5+20 · DeepSeek 配置修复

- **代码**：`ace22b6`。
- **变更**：聊天机器人、技能代理和旅行规划统一使用 `DEEPSEEK_API_KEY`；默认模型为 `deepseek-flash`，接口地址为 `https://api.deepseek.com`。
- **数据库**：无结构变更，Alembic 保持 `0014_chatbot`。
- **备份**：`/var/backups/daily-consume/daily-consume-pre-1.4.5-20261012T143845Z/server-code.tar.gz`；SHA256 为 `8b3074b93dc2848a2557c581111d21cdaf9c1781761764bb23bdc5babc1065d3`。
- **备份范围**：本次替换前的六个文件：`database.py`、`skill_agent/engine.py`、`skill_agent/router.py`、`travel.py`、`travel_planner_core/config.py`、`travel_planner_core/services/llm_service.py`。该归档不含数据库备份。
- **验收**：API 与 Nginx 均为 active；服务进程确认已配置 DeepSeek Key；内网 health 正常；使用固定 CA 的公网 HTTPS health 返回 200；聊天路由未认证请求返回 401。
- **过程记录**：首次检查使用的交互式 `runuser` 环境未继承 systemd 环境，部署在重启前中止；确认服务进程环境后重启成功。Alembic 检查切换到 `/opt/daily-consume` 后返回 `0014_chatbot (head)`。
- **回滚依据**：恢复上述六个文件并重启服务；此次无需回退数据库。保留服务器当前 `.env` 与 TLS 私钥。
- **详细记录**：[1.4.5-deployment.json](release-notes/1.4.5-deployment.json)。新 APK 已发布，旧 `v1.4.4+19` 的 APK 资产已删除，旧 Release 说明与清单保留。

## 2026-10-12 · 1.4.4+19 · 科研工具与聊天机器人

- **代码**：最终后端修复提交 `fa16c9f`。
- **变更**：上线科研论文搜索、PDF 下载及账号隔离的聊天对话与消息接口；修正论文下载路由的后台任务导入。
- **数据库**：升级至 `0014_chatbot`，新增聊天对话与消息表。
- **备份目录**：`/var/backups/daily-consume/daily-consume-pre-1.4.4-20261012T135525Z`；数据库归档为该目录下的 `daily_consume.dump`，代码归档文件名在原记录中未记载。
- **校验**：数据库 SHA256 为 `71be8c8ac5e6cff19dbcdc57981aaee1325ad309ef071f1e8579f8a262ea6ac5`；代码 SHA256 为 `7e933f25b132cd7eaeac6191c0f0baac9aaf195c9c943d9950f2f9a830814269`；数据库归档通过 `pg_restore --list`。
- **验收**：API 与 Nginx 均为 active；内网及固定 CA 公网 HTTPS health 正常；科研和聊天路由未认证请求均返回 401；Alembic 为 `0014_chatbot (head)`。
- **回滚依据**：使用本次部署前配套的代码和数据库备份；存在聊天记录时，迁移会拒绝回退删表，恢复方案见下文。
- **详细记录**：[1.4.4-deployment.json](release-notes/1.4.4-deployment.json)。

## 2026-10-12 · 1.4.3+18 · 情侣争执与反思

- **代码**：部署提交在原记录中未记载。
- **变更**：上线争执日历、个人反思、共同约定与评论。
- **数据库**：升级至 `0013_couple_conflicts`；原有 36 张表（含 Alembic 版本表）迁移前后行数一致。
- **备份目录**：`/var/backups/daily-consume/daily-consume-pre-1.4.3-20261012T075947Z`；原记录未记载归档文件名。
- **校验**：数据库 SHA256 为 `c2f24f3b83fe3da69d2d9c4a85894c467448c821a6e94d238f8b29e93477f677`；代码 SHA256 为 `397b0eae0386f095c113578b84246d3d1d79e73664c182f47f9dacdacf2bce44`；数据库归档通过 `pg_restore --list`。
- **验收**：API 与 Nginx 均为 active；8 组真实 HTTPS 检查通过，覆盖邀请、共享日历、相册、访问隔离、反思和共同确认；本次临时账号与空间已清理。
- **回滚依据**：使用部署前的代码与数据库配套备份；已有争执或反思数据时，迁移拒绝回退删除。
- **详细记录**：[1.4.3-deployment.json](release-notes/1.4.3-deployment.json)。

## 2026-10-11 · 1.4.1 · 技能实验室

- **代码**：部署提交未记录；新增技能代理、知识库和评测相关接口。
- **数据库**：升级至 `0010_skill_agent`，新增 10 张账号隔离业务表，共 35 张业务表。
- **备份**：数据库 `/var/backups/daily-consume/daily_consume-pre-1.4.1-20261011T045054Z.dump`；代码 `/var/backups/daily-consume/daily-consume-code-pre-1.4.1-20261011T045307Z.tar.gz`，代码快照不含 `.env` 和虚拟环境。
- **验收**：数据库约 9.7 MB，`pg_restore --list` 通过；服务 active、health 正常。数据库与代码 SHA256 见[原始记录](access-api/account-server.md#服务器)。
- **回滚依据**：使用该次配套备份；技能实验室迁移回退会删除相关数据，按下文数据库恢复流程处理。

## 2026-10-11 · 1.4.0 · 目标体重与旅行规划

- **代码**：部署提交未记录；高德地图 Key 已配置。
- **数据库**：升级至 `0009_body_weight_goal`，新增目标体重设置表；保留 `0008_other_expenses` 与既有记录，共 25 张业务表。
- **备份**：数据库 `/var/backups/daily-consume/daily_consume-pre-1.4.0-20261010T160016Z.dump`；代码 `/var/backups/daily-consume/daily-consume-code-pre-1.4.0-20261010T160016Z.tar.gz`，代码快照不含 `.env` 和虚拟环境。
- **验收**：数据库归档检查通过；服务 active、health 正常。数据库与代码 SHA256 见[原始记录](access-api/account-server.md#服务器)。
- **回滚依据**：使用该次配套备份并检查新旧代码对数据库结构的兼容性。

## 2026-10-06 · 1.3.6 · AI 分析与每日总结

- **代码**：部署提交未记录；上线 AI 接口及 `prompts/` 提示词目录。
- **数据库**：部署时已为 `0007_profile_age`，本次无新增迁移，共 23 张业务表。
- **备份**：数据库 `/var/backups/daily-consume/daily_consume-pre-1.3.6-20261006T080857Z.dump`；代码 `/var/backups/daily-consume/daily-consume-code-pre-1.3.6-20261006T080857Z.tar.gz`，代码快照不含 `.env` 和虚拟环境。
- **验收**：数据库归档目录检查通过，共 167 项；API 与 Nginx 均为 active；两个 AI 路由与提示词加载成功，HTTPS health 正常。SHA256 见[原始记录](access-api/account-server.md#服务器)。
- **回滚依据**：本次无结构变更，可使用代码快照恢复应用；数据库备份另行保留。

## 2026-10-05 · 1.3.4+11 · 多图回忆相册

- **代码**：部署提交未记录；修复发布接口并上线多图相册。
- **数据库**：升级至 `0006_memory_albums`，新增有序相册照片表并回填旧单图回忆，共 23 张业务表。
- **备份**：数据库 `/var/backups/daily-consume/daily_consume-pre-1.3.4-20261004T195407Z.dump`；代码 `/var/backups/daily-consume/daily-consume-code-pre-1.3.4-20261004T195407Z.tar.gz`。
- **验收**：数据库归档目录检查通过；服务与 Nginx 均为 active；Alembic、health 及 7 组真实 HTTPS 情侣空间检查通过；临时账号已清理，报告位于 `/opt/daily-consume/couple-api-checks.json`。
- **回滚依据**：使用配套备份；存在多图或滑动相册时，迁移拒绝通过降级丢弃数据。数据库 SHA256 见[原始记录](access-api/account-server.md#服务器)。

## 2026-10-04 · 1.3.3 · 番茄钟

- **代码**：部署提交未记录。
- **数据库**：升级至 `0005_pomodoro`，新增番茄钟设置、专注事项与完成记录三张表，共 22 张业务表。
- **备份**：数据库 `/var/backups/daily-consume/daily_consume-pre-1.3.3-20261004T104935Z.dump`；代码备份与校验和未记录。
- **验收**：数据库归档通过 `pg_restore --list`；API health 与新路由鉴权检查通过。
- **回滚依据**：已有番茄钟数据时，迁移拒绝回退删除；恢复前须补齐匹配的代码版本。

## 2026-10-04 · 1.3.1 · 头像与回忆时间线

- **代码**：部署提交未记录。
- **数据库**：升级至 `0004_avatar`，`users` 新增受大小约束的头像字段，共 19 张业务表。
- **备份与验收**：独立备份路径、校验和及本次检查明细未记录。
- **回滚依据**：已有头像时，迁移拒绝回退删除字段；回退前需确认代码和数据库的可用备份。

## 2026-10-04 · 1.3.0 · 日历、情侣空间与 Alembic 接管

- **代码**：部署提交未记录。
- **数据库**：正式接管 Alembic 并升级至 `0003_couple`，共 19 张业务表；原有 13 张表的行数与内容指纹一致。
- **备份**：原记录说明代码和数据库备份在 `/var/backups/daily-consume/`，具体文件名及校验和未记录。
- **验收**：真实 HTTPS 情侣功能及原业务检查通过。
- **回滚依据**：先定位并核实该次备份；`0001_baseline` 接管已有数据，禁止直接降至 `base`。

## 2026-10-04 · 1.2.1 · 女性健康

- **代码**：部署提交未记录。
- **数据库**：当时尚未由 Alembic 接管；保留原有 10 张表，新增三张女性健康表，共 13 张表；`users` 新增性别字段。
- **验收**：原有表迁移前后的行数与内容指纹一致。
- **备份与回滚依据**：具体备份路径、校验和与回滚操作未记录；后续 `0001_baseline` 冻结了此版结构。

## 2026-10-03 · 1.2.0+5 · 账号与服务器存储

- **代码**：部署提交未记录；账号 API、PostgreSQL 和 Nginx HTTPS 已用于验证。
- **数据库**：当时尚未由 Alembic 接管，账号隔离和旧 SQLite 导入已实现。
- **验收**：服务器回环 HTTPS、FastAPI 与 PostgreSQL 的 11 组检查通过；临时账号已清理。**当次公网 TCP 443 连接超时，公网登录尚未验证通过**。
- **备份与回滚依据**：具体备份路径、校验和与回滚操作未记录。
- **详细记录**：[账号功能验证记录](access-api/account-validation.md)。公网连通性结论仅描述该次检查，不代表后续状态。

## 日期未记录 · 1.3.7 · 其他消费

- **代码**：部署提交未记录；上线账号隔离的其他消费接口。
- **数据库**：升级至 `0008_other_expenses`，新增 `other_expense_entries`；1.4.0 部署前线上已有 24 张业务表。
- **时间范围**：原记录确认发生在 1.4.0 部署之前，未记载具体部署日期。
- **备份、验收与回滚依据**：未记录，不能以客户端发布时间代替服务器部署时间。

## 回滚方式

### 仅更新代码

使用该次部署前的代码归档，按记录的文件范围恢复到 `/opt/daily-consume`，检查依赖版本和文件归属，再重启 `daily-consume.service`。保留现有环境文件、TLS 证书与私钥；不因代码回退自动降级数据库。完成后检查服务状态、内网 health、固定 CA 的公网 `/api/v1/health` 和涉及的登录后业务。

1.4.5 的代码归档仅包含六个替换文件，不能作为完整服务器安装包或数据库备份使用。

### 涉及数据库结构

先确认目标代码是否兼容现有结构。只有迁移的 `downgrade()` 已验证可逆且数据条件满足时才执行降级；已有聊天、相册、头像或反思等数据时，部分迁移会主动拒绝删除。

需要恢复数据库备份时，安排维护窗口、停止业务写入，先保留当前库备份，再使用已核实的数据库归档和匹配代码恢复。恢复到历史快照会丢失该快照之后新增或修改的数据，须先确定这些数据的处理方式。备份 SHA256 与 `pg_restore --list` 检查用于确认文件与归档目录，实际恢复验证需在隔离数据库中完成。具体操作见 [数据库回退与失败处理](database-migrations.md#回退与失败处理)。

原记录缺少备份或提交时，先核实所需恢复材料，不能从版本号推定备份文件已存在。

## 后续记录约定

- 每次部署新增一节，记录日期和时区、应用版本（若有）、后端提交、变更内容、数据库迁移前后版本、备份范围与路径、校验和、验收结果、回滚依据。
- 仅后端部署用“后端部署 · 提交号或变更名称”作为标题，不强行对应 APK 版本。
- 同一天多次部署分别记录实际完成时间；失败尝试与最终结果写明，不将计划或未执行迁移记成已上线。
- 有结构化记录时继续保存 `release-notes/<版本>-deployment.json` 并从本文链接；只写有证据的结果，未知项标记“未记录”。
- 文档仅记录配置名称及是否就绪，不保存密码、API Key、AppSecret、访问令牌或带凭证的数据库连接串。

新增条目可使用以下模板：

```markdown
## YYYY-MM-DD HH:mm（Asia/Shanghai）· 版本或后端部署名称

- 代码提交：
- 部署内容：
- 数据库：迁移前版本 → 迁移后版本，或无结构变更。
- 备份：范围、路径、SHA256、归档与恢复验证结果。
- 验收：服务状态、HTTPS health、鉴权及相关业务检查结果。
- 过程与遗留问题：
- 回滚依据：目标代码、数据库兼容性及备份范围。
- 详细记录：JSON 或检查报告链接（如有）。
```
