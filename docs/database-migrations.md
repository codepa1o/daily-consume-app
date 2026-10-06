# PostgreSQL 数据库迁移

日期：2026-10-04。本项目使用 Alembic 管理服务器 PostgreSQL 表结构，业务查询仍使用 psycopg 和手写 SQL。应用启动不执行建表或改表；数据库迁移在部署时独立执行。

## 文件与连接配置

- `server/alembic.ini`：迁移路径配置，支持从项目根目录通过 `-c server/alembic.ini` 执行。
- `server/migrations/env.py`：连接数据库、串行执行迁移、维护版本表。
- `server/migrations/versions/0001_baseline.py` 与 `0001_schema.sql`：冻结的 1.2.1 基线，共 13 张业务表。
- `server/migrations/script.py.mako`：新增迁移模板，未填写的升级和回退操作会报错，避免发布空迁移。
- `server/database.py`：API 与迁移共享的 `DATABASE_URL` 配置。
- `server/migrations/versions/0002_journal.py`：生活日历增量迁移，新增 `journal_entries` 表与索引，已有日记时拒绝回退删表。
- `server/migrations/versions/0003_couple.py`：情侣空间增量迁移，新增空间、成员、照片回忆、留言和表情五张表；1.3.0 部署后共 19 张业务表。冻结基线仍为原 13 张表。空间有数据时拒绝回退删表。
- `server/migrations/versions/0004_avatar.py`：为 `users` 增加最大 1 MiB 的头像 `BYTEA` 字段，不新增业务表；1.3.1 部署后共 19 张业务表。已设置头像时拒绝回退移除列。
- `server/migrations/versions/0005_pomodoro.py`：新增账号专属的番茄钟设置、专注事项与完成记录三张表；1.3.3 部署后共 22 张业务表。非空数据时拒绝回退删除。
- `server/migrations/versions/0006_memory_albums.py`：增加回忆照片展示模式及有序相册表，并将原有单张照片回填到相册第 0 张；1.3.4 部署后为当前 head，共 23 张业务表。存在多图或滑动相册时拒绝降级丢弃数据。
- `server/migrations/versions/0007_profile_age.py`：为 `users` 增加可选年龄字段，限制为 1–120 岁；不新增业务表。1.3.5 及后续版本部署后为当前 head，共 23 张业务表。

`DATABASE_URL` 接受 psycopg/libpq 的连接字符串或 PostgreSQL URI，不必转换为 SQLAlchemy URL。未设置时，使用 `dbname=daily_consume user=daily_consume host=/var/run/postgresql`，由系统用户 `daily-consume` 通过 peer 映射认证。不要将数据库密码提交到仓库。迁移使用连接的 `current_schema()`，版本表也位于同一 schema；本地测试通过独立 `search_path` 隔离。

安装后端依赖并进入 `server` 目录、激活后端虚拟环境后运行：

```sh
python -m pip install -r requirements.lock
alembic current
alembic heads
alembic history
alembic upgrade head
```

Windows 可使用 `.venv\Scripts\alembic.exe`；项目根目录可使用 `python -m alembic -c server/alembic.ini upgrade head`。这些命令连接的是 `DATABASE_URL` 指定的数据库，应用和迁移应使用相同配置。

## 首次初始化与已有数据库接管

空数据库执行 `upgrade head` 创建全部业务表、序列、主外键、唯一约束、检查约束和索引，并写入 `alembic_version`。

已有 1.2.1 数据库同样执行 `upgrade head`。首次迁移先检查表集合，再在事务内建立随机名称的参考 schema，使用同一 PostgreSQL 实例生成标准结构，比较字段顺序、类型、可空性、默认值、约束名称和定义、索引及序列配置。匹配时仅登记基线版本，不重建业务表、不读取或更新业务行、不重置序列当前值；参考 schema 随后清理。

缺表、多表、字段或约束不一致时，迁移报出涉及的对象类别和表名，并回滚，不登记成功版本。仅有旧版 10 张表的数据库需要先完成旧版到 1.2.1 的结构升级，再接管；不能用 `stamp head` 跳过差异。首次接管需要数据库用户拥有创建 schema 的权限，现有 bootstrap 创建的数据库所有者满足要求。

已执行的基线脚本及 SQL 快照不可修改。后续每次数据库变更都新增 revision，不再维护原来的 `server/schema.sql`。首次接管完成后的重复 `upgrade head` 不重跑基线；Alembic 版本一致不代表会自动检测后来手工改表产生的结构漂移。

## 后续改表流程

1. 创建迁移文件：`alembic revision -m "add_example_column"`。
2. 在 `upgrade()` 编写新表、字段、索引或约束操作。可使用 `op.add_column`、`op.create_table`，或者 `op.execute` 执行 SQL。
3. 在 `downgrade()` 编写逆向操作。不可逆的变更必须明确报错并解释恢复方式。
4. 在测试数据库运行升级、业务检查及可逆回退，再提交迁移文件和对应业务代码。
5. 部署数据库变更时执行 `alembic upgrade head`。

示例：

```python
def upgrade():
    op.add_column('users', sa.Column('example_note', sa.Text(), nullable=True))


def downgrade():
    op.drop_column('users', 'example_note')
```

新增非空字段时先考虑已有行的默认值或数据回填。迁移脚本中的 SQL 和数据转换逻辑固定在对应 revision 中，不导入会随业务版本变化的 API 实现。保持单一 head，出现并行分支时先整理迁移顺序或使用 Alembic merge，再发布。

当前没有 SQLAlchemy 表元数据，使用手写迁移，`--autogenerate` 会明确拒绝。仅修改 Pydantic 输入模型或业务 SQL不会生成数据库迁移。

## 服务器部署

部署前备份数据库并核实可恢复。上传 `app.py`、`journal.py`、`couple.py`、`database.py`、`alembic.ini`、完整 `migrations/` 目录、依赖文件及更新后的 `deploy.sh`，同时保留现有 service 和 Nginx 配置。情侣邀请码预览及加入使用认证限流规则，须同步上传新 Nginx 配置。迁移目录中的 `.py`、`.sql`、`.mako` 都必须上传。

服务器仍通过 `server/deploy.sh` 部署。脚本安装依赖后，从 `/opt/daily-consume` 执行：

```sh
runuser -u daily-consume -- /opt/daily-consume/venv/bin/alembic \
  -c /opt/daily-consume/alembic.ini upgrade head
```

迁移成功后才安装服务配置并重启 API，失败返回非零退出码并停止部署。服务配置的两个 worker 都不会执行迁移。在线迁移使用事务级 advisory lock，防止两个 Alembic 进程同时读取旧版本并改表。

默认配置使用 peer 认证，所以不能直接以 root 连接数据库。若使用自定义 `DATABASE_URL`，必须让迁移进程和 systemd 服务获得相同配置；可通过受保护的环境文件管理，不要把凭证写入命令历史。非兼容改表应安排维护窗口或分阶段发布，确保执行迁移时仍在运行的旧版 API 能处理新结构。

## 回退与失败处理

```sh
alembic downgrade -1
alembic downgrade <目标revision>
```

以上仅用于已验证可逆的增量迁移。`0001_baseline` 可能接管已有正式数据库，因此禁止降至 `base`，避免删除整库业务数据。删除字段、删除表或数据转换不能保证恢复旧数据；需要使用已验证的备份，而不只是回退表结构。

当前迁移统一在 PostgreSQL 事务中运行，失败时 DDL 和版本更新一起回滚。需要 `CREATE INDEX CONCURRENTLY` 等事务外操作时，应另行设计该 revision 的失败恢复与串行执行，不能直接放进当前环境。

`alembic upgrade head --sql` 可生成空库初始化 SQL，供审阅；离线模式无法检查已有数据库结构，不用于已有库接管。

## 验证

先安装锁定的运行依赖，再安装测试所需的 `httpx`。设置指向独立测试数据库的 `TEST_DATABASE_URL` 后，在项目根目录执行：

```sh
python -m unittest discover -s server -p 'test_*.py' -v
```

测试使用随机 schema 并自动清理，覆盖空库初始化、重复升级、全部 13 张业务表的数据和序列保留、并发 CLI 升级、结构差异拒绝、基线回退保护、增量升级与回退、失败事务回滚，以及现有女性健康 API 行为。未设置测试连接时数据库测试会跳过，不能将跳过视为迁移验证通过。

2026-10-04 在单独初始化、仅监听本机的 PostgreSQL 18.0 实例验证：7 项迁移检查和 10 项女性健康 API 检查通过；迁移检查同时验证 PostgreSQL URI 配置。锁定依赖在独立虚拟环境安装成功，`pip check` 通过；Linux shell 语法检查通过。该验证未连接或修改线上数据库，线上 Alembic 接管须通过上述部署流程执行。

参考：[Alembic 教程](https://alembic.sqlalchemy.org/en/latest/tutorial.html)、[自动生成迁移的限制](https://alembic.sqlalchemy.org/en/latest/autogenerate.html)、[SQLAlchemy psycopg 方言](https://docs.sqlalchemy.org/en/20/dialects/postgresql.html#module-sqlalchemy.dialects.postgresql.psycopg)。
