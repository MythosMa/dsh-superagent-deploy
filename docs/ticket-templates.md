# 拆工单模板：Flutter + Go + MySQL 项目

> 原则：**一个工单 = 一个可评审的增量**。拆得越准，PR 越容易过；一次塞太多 → 超时/失败/脏评审。
> 每个工单都要：标题清晰、验收标准可验证、约束写死、上下文链接给全。
> 派活方式：在 Issue / PR 里发**新评论** `@<agent-account> <本模板内容>`（不要编辑旧正文，正文改动不触发）。

## 拆分总表（建议顺序）

| # | 工单 | 依赖 | 产出 | 验收点 |
|---|------|------|------|--------|
| 1 | 仓库骨架 | - | Flutter 前端 + Go 后端 + docker-compose(MySQL) + README | `docker compose up` 起服、两端 hello world 可跑、CI 绿 |
| 2 | Go 后端最小 API | 1 | `/healthz` + 路由骨架 + 配置加载 | `curl /healthz` 返回 200；`go test ./...` 过 |
| 3 | MySQL 数据层 | 2 | 表结构 + 迁移脚本 + 种子数据 + DAO | 迁移可重复执行；DAO 单测过 |
| 4 | 用户/业务 API | 3 | 1~2 个业务接口（CRUD） | 接口测试过；错误码规范 |
| 5 | Flutter 页面 | 2 | 1~2 个页面 + API 对接 + 状态管理 | `flutter analyze` 无错；`flutter test` 过 |
| 6 | 前后端联调 | 4,5 | 端到端流程（登录/列表/详情） | 冒烟脚本或手动流程跑通 |
| 7 | 收尾 | 全部 | README 更新、环境示例、CI（可选） | 文档可照做、CI 绿 |

> 每完成一单，**你 merge 后**再发下一单（新评论），保持"单线程评审"节奏。

## 工单正文模板（复制即用）

````markdown
@<agent-account> 【<阶段名>】

**目标**
<一句话说明要做什么、为什么>

**范围（只做这些）**
- ...
- ...

**验收标准（必须可验证）**
- [ ] ...
- [ ] `go test ./...` / `flutter analyze` / `flutter test` 通过
- [ ] ...

**约束**
- 后端：Go <版本>，框架 <gin/chi/...>；不要引入未在 go.mod 的依赖
- 前端：Flutter <版本>，状态管理 <riverpod/provider>；不要改已有设计系统
- 数据库：MySQL 8.4，迁移放 `migrations/`，改表必须写迁移
- 分支：`agent/<短名>`；只改本工单范围
- 不合并、不自动 merge；结束时开 PR 并写清验证方式

**上下文**
- 上一单 PR：<链接>
- 相关 Issue/ADR：<链接>
- 本地验证命令：<命令>

**交付**
- 一个 PR（说明改动、验证步骤、风险）
- 若被外部依赖卡住：在 PR 里说明，并报告 blocked（附具体问题）
````

## 各阶段的具体写法示例

### 工单 1：仓库骨架
````markdown
@<agent-account> 【阶段 1/7 仓库骨架】

**目标**：搭建可运行的 Flutter + Go + MySQL 项目骨架。
**范围**：目录结构（backend/、frontend/、migrations/）、docker-compose.yml（mysql 8.4 + 后端）、README、Makefile。
**验收**：
- [ ] `docker compose up -d` 后 `curl localhost:8080/healthz` 返回 200
- [ ] `cd frontend && flutter pub get && flutter analyze` 无错误
- [ ] README 能照着把项目跑起来
**约束**：最小骨架，不做业务；Go 用标准库 net/http 即可；前端用 `flutter create` 生成后只加一个首页。
````

### 工单 2：Go 后端最小 API
````markdown
@<agent-account> 【阶段 2/7 后端最小 API】

**目标**：健康检查 + 路由骨架 + 配置加载。
**范围**：`GET /healthz`、`GET /api/version`、环境变量配置、启动日志。
**验收**：
- [ ] healthz 返回 200 + JSON `{"status":"ok"}`
- [ ] `go test ./...` 通过（至少 1 个 handler 测试）
- [ ] 配置缺失时启动报错清晰
**约束**：不接数据库；不引入 ORM；错误响应统一 `{code,message}`。
**上下文**：骨架 PR <链接>；MySQL 连接串由执行环境变量提供（见下）。
````

### 工单 3：MySQL 数据层
````markdown
@<agent-account> 【阶段 3/7 MySQL 数据层】

**目标**：建表 + 迁移 + 种子 + DAO。
**范围**：`users`、`items` 两张表；`migrations/001_init.sql`；DAO 层与单测。
**验收**：
- [ ] 迁移在空库可执行，且重复执行不报错（幂等）
- [ ] 种子数据可插入
- [ ] DAO 单测（sqlmock 或容器内真实 MySQL）通过
**约束**：只做数据层；不写业务 handler；表名/snake_case；必须写迁移，不允许手改表。
**上下文**：MySQL 连接信息（执行环境变量）：
`SUPER_AGENT_MYSQL_HOST=mysql` `PORT=3306` `USER=sa_worker` `PASSWORD=...` `DB=super_agent_test`
````

### 工单 4：业务 API / 工单 5：Flutter 页面 / 工单 6：联调
按同样格式，**每单只推进一层**；联调单要给出"端到端验收步骤"，例如：
````markdown
**验收**：
- [ ] 启动全栈后，前端首页能加载列表（截图/接口日志）
- [ ] 创建一条数据，刷新后可见
- [ ] 后端日志无 5xx
````

## 串联与节奏

1. 第 1 单 merge 后 → 第 2、3 单（可先后或并行，但建议单线程）
2. 每单 PR 里自测通过再开；你 merge 后发下一单新评论
3. 出现 blocked（缺依赖/需求不清）→ 在 PR 里说明，按提示回复即可
4. 项目级约定（命名、架构、依赖）写进 **Prompts 的团队段落**，不要每单重复

## MySQL 连接信息给 worker 的方式

在面板 **Settings → Execution → 执行环境变量** 里加（示例）：

| key | value | 说明 |
|---|---|---|
| `SUPER_AGENT_MYSQL_HOST` | `mysql` | compose 网络内服务名 |
| `SUPER_AGENT_MYSQL_PORT` | `3306` | 容器内端口 |
| `SUPER_AGENT_MYSQL_USER` | `sa_worker` | 专用低权限账号 |
| `SUPER_AGENT_MYSQL_PASSWORD` | `<mysql.env 里的值>` | 仅测试库 |
| `SUPER_AGENT_MYSQL_DB` | `super_agent_test` | 测试库 |

> 注意：这些值会出现在 worker 的提示词里（模型需要）；仅用于测试库，不要用生产凭据。

## 硬限制（避免踩坑）

- prepare 命令最多 **10 分钟**（clone/依赖安装别塞太重）
- 单轮后台任务最多 **30 分钟**（长任务拆小）
- 一个工单只对应一个 PR；大改动拆成多单
- 派活用**新评论**；改 Issue 正文不触发
- 工单要写明"**不合并**"，合并始终由人做
