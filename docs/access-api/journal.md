# 生活日历接口与验证

日期：2026-10-04。客户端：1.3.1+9。状态：生活日历后端已上线并通过真实 HTTPS 的个人记录隔离检查。客户端签名 APK 更新包见 [GitHub Release](https://github.com/codepa1o/daily-consume-app/releases/tag/v1.3.1%2B9)。

## 实现范围

身体页底部新增月历、日期记录标记、当天列表、日记编辑、普通备忘、简单待办和全部记录搜索。支持历史补写、未来备忘、同日多条、改日期、删除、完成/取消完成及跨日期定位。身体指标与日历的加载和错误状态分别处理。

业务按账号存入服务器，不新增本地业务数据库或磁盘缓存。编辑中的内容只保留在页面内存，不能跨重启恢复。

## 接口契约

以下路径相对于现有 `api/v1/`，全部需要当前账号 Bearer 会话。所属账号从会话取得，拒绝输入 user_id。

| 方法 / 路径 | 输入与行为 |
| --- | --- |
| GET `journal/calendar` | month=YYYY-MM，返回 days；每日包含 entry_date、diaries、memos、pending、completed 数量 |
| GET `journal/entries` | 可选 date、kind（diary/memo）、q；limit 默认 50，范围 1–100；offset 非负；返回 items、total、has_more |
| GET `journal/entries/{id}` | 返回完整正文、日期、类型、待办状态、version、创建/修改时间 |
| POST `journal/entries` | 创建并返回 201 和完整记录；需随机 32 位小写十六进制 client_request_id |
| PUT `journal/entries/{id}` | 全部可编辑字段及 expected_version；成功 version 加一 |
| DELETE `journal/entries/{id}` | 查询参数 expected_version；成功返回 deleted=true |

创建正文示例：

```json
{
  "entry_date": "2026-10-04",
  "kind": "memo",
  "title": "今天的安排",
  "content": "买训练用的弹力带",
  "is_todo": true,
  "completed": false,
  "client_request_id": "7b6c5d4e3f2019283746556677889900"
}
```

修改使用相同可编辑字段，将 client_request_id 替换为 expected_version。随机创建标识只在同一次提交重试时复用，不作为所有新建操作的固定值。

归属日期使用 PostgreSQL DATE，今天与范围校验按 Asia/Shanghai；支持 2000-01-01 至当前年份后 10 年的 12-31。日记不允许未来日期，备忘允许。标题最多 100 个字符，正文最多 20,000 个字符；清理首尾空白，日记正文必填，备忘标题/正文至少一项非空。日记不能是待办，普通备忘不能已完成，布尔输入严格校验。

月历只返回数量；列表正文截取前 160 个字符，详情返回完整内容。待办操作先读详情，避免把摘要写回正文。默认列表按日期、创建时间、ID 降序；指定日期时先按未完成待办、日记/普通备忘、已完成待办分组排序，再分页。搜索覆盖全部日期，按文字匹配标题/正文，关键词中的 `%`、`_` 和反斜线不作为通配符。

## 去重、冲突与编辑保护

同账号同 client_request_id 只插入一次。服务器保存原创建输入的 SHA256，原请求在记录被编辑后仍可识别；相同标识携带不同内容返回 409，不覆盖原记录。不同账号可以分别使用相同标识。

更新/删除以账号、记录 ID 和 version 为原子条件；旧版本操作返回 409，不存在或不属于本账号统一 404；401 走会话失效流程，422 为输入错误。

提交超时或服务器故障时保留提交快照，暂停修改并允许重试同一提交。更新重试返回 409 时读取详情核对目标内容，已达到目标则确认成功；否则保留本页输入，支持查看最新内容，再由用户明确选择使用最新内容或基于最新版本继续编辑。不自动覆盖其他设备的修改。

保存成功后刷新日历；刷新失败显示加载错误，不误报保存失败。待办操作提交明确 completed 状态，不使用会因重试反转两次的 toggle。切换账号立即清空旧账号页面内容；离开未保存编辑页给出保存、放弃、继续编辑选项。

## 验证记录

- `flutter analyze`：通过。
- `flutter test`：38 项通过，包含新增 10 项日历/编辑/搜索验证。
- 真实 PostgreSQL 18.6 独立实例执行 `python -m unittest discover -s server -p 'test_*.py' -v`：23 项通过，无跳过。覆盖既有女性健康、迁移和新增日记 API。
- 新接口验证账号间访问拒绝、认证、并发创建去重、原创建请求在编辑后的重试识别、并发修改冲突、旧版本删除拒绝、改日期后摘要变化、分组分页与搜索特殊字符。
- 数据库约束和非空日记表回退保护通过；基线接管保留原 13 张业务表的数据与序列。
- 360 像素宽、1.6 倍字体的 Flutter 页面验证无溢出；使用中文字体渲染实际组件预览并检查。
- `flutter build apk --release`：通过。`python scripts/publish_github_release.py --dry-run` 本地验证版本、签名及内嵌更新日志一致，没有请求或上传。

测试库在本机 127.0.0.1 的独立端口运行，用随机 schema 隔离并自动清理，没有连接正式数据库。使用 [EDB 官方便携二进制](https://www.enterprisedb.com/download-postgresql-binaries)，工具/数据位于 Git 忽略的 `.dart_tool/journal-validation/`，验证结束后停止实例。Android 真机交互验收尚未执行。

## 部署与回退

新增 revision `0002_journal` 基于 `0001_baseline`，新增 journal_entries 表及索引，不修改冻结基线或既有表。发布前先部署后端，再发布客户端。

上传必须包含新增 `server/journal.py`（服务器对应 `/opt/daily-consume/journal.py`），以及 app.py、database.py、alembic.ini、完整 migrations/、锁定依赖和现有部署文件。只上传 app.py 会导入失败。按[迁移指南](../database-migrations.md)备份并运行已有 deploy.sh，成功执行 `alembic upgrade head` 后才重启 API。

旧业务接口兼容。新客户端连到未升级的后端时，日历提示服务暂不可用，原身体功能仍能使用。非空 journal_entries 表拒绝 downgrade 删表，优先回退应用版本并保留数据；不能用 stamp 跳过迁移。

后续提醒、心情、标签、模板、生活概览、附件、导出、日记锁、持久草稿及回顾继续列在[TODO](../calendar-diary-TODO.md)，本版不提供通知、重复待办或离线草稿。
