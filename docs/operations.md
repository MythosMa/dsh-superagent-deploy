# 运维手册：多仓库、合作者、日常操作

> 本文承接 [README.md](../README.md)。当前部署形态：
> `~/dsh-superagent-data/`（profile / gh-agent / state / mysql）+ 镜像 `dsh-superagent:local`
> + 容器 `dsh-superagent` / `dsh-superagent-mysql`。
> 架构约束先记住：**一个部署 = 一个仓库**（Source 只监听配置仓库，PR 归属也只认它）。

---

## 1. 多仓库策略

### 1.1 方案 A：一条命令切源（推荐，单实例）

```bash
# 切到另一个仓库（owner/name 或完整 URL 均可）
scripts/switch-repo.sh <agent-account>/new-repo
# 或
scripts/switch-repo.sh https://github.com/owner/name.git

# 只想切源、保留本地历史（旧线程可能与新仓库同号线程混淆，一般不建议）
scripts/switch-repo.sh <agent-account>/new-repo --keep-history
```

脚本做的事：更新 `source:github` 的 repository（保留 cli 等其余配置）→ 保存触发自动重启
→ 轮询等待 `runtime=ready` + `setup=null` + `accounts.repository` 匹配 → 退订旧仓库的订阅线程
→（默认）**备份并清理旧仓库的本地历史**：thread/trigger/trigger_thread/disposition/ticket/
decision/effect/outbox + 每线程游标（`github-cursor:*`、`github-ci:*`、`github-retry`、`thread-*`）
→ 重启并再次等待就绪。
备份位置：`<stateDir>/backups/orchestrator-switch-<时间戳>.sqlite`。

**切源前提**：
1. agent 账号（<agent-account>）对该仓库有 **Write** 权限（否则 setup 报 `repositoryReadOnly`）；
2. 旧仓库**没有在途工单**（切源后旧仓库的 PR 会失去跟踪，最好先 merge/close）；
3. 默认会清理旧仓库历史（有备份）；要保留历史用 `--keep-history`。

### 1.2 方案 B：第二实例（多仓库并行，互不干扰）

```bash
# 创建实例 b：面板 3083 / MySQL 13307
scripts/add-instance.sh b 3083 13307
docker compose -f instance-b/compose.yaml up -d

# 首个实例之外，再给 b 配 source/policy（或用 switch-repo 指向 3083）：
DSH_SUPERAGENT_URL=http://127.0.0.1:3083 scripts/switch-repo.sh owner/repo-b
```

- 实例共享同一镜像、独立 profile/state/mysql/端口；gh-agent 凭据自动复制
- 两个实例可共用同一个 <agent-account> 账号（通知按仓库过滤，互不串）
- 适合长期多项目并行；单个实例仍是最省心的默认

### 1.3 选型建议

| 场景 | 选择 |
|---|---|
| 偶尔换项目 | 方案 A（切源） |
| 多个长期仓库同时活跃 | 方案 B（每仓库一实例） |
| 想彻底隔离账号 | 每实例配独立 GitHub 账号（改 gh-agent 登录） |

---

## 2. 让 super-agent 成为合作者（你创建仓库，给它开权限）

适用：仓库在你的账号/组织下，agent 只拿 **Write**（推荐的安全姿势）。

```
① 你创建仓库（网页或 gh CLI，<your-account> 身份）
② 仓库 Settings → Collaborators → Add people → <agent-account> → Write
③ 让 agent 接受邀请：
   scripts/accept-invites.sh
④ 切源：
   scripts/switch-repo.sh <你的账号>/<仓库名>
⑤ 验证：面板 Overview 的 setup 无缺项、Sources → GitHub state=ready
⑥ 在你的仓库 Issue 里发新评论 @<agent-account> 派活
```

**注意**：
- 私有仓库同样支持（只要 <agent-account> 是协作者）；
- 邀请未接受前切源，setup 会报 `repositoryUnreadable` / `repositoryReadOnly`；
- 若仓库归你（owner），合并权天然在你手上，agent 只开 PR——这正是推荐形态。

---

## 3. 拆工单

见 [ticket-templates.md](ticket-templates.md)：Flutter + Go + MySQL 的 7 单拆分模板、
每单的验收标准写法、MySQL 执行环境变量配置、硬限制。

一句话：**一个工单一个增量，merge 后再发下一单的新评论**。

---

## 4. 日常运维

### 4.1 启动 / 停止 / 状态

```bash
cd <部署目录（deploy 的上级，即仓库根）>
docker compose -f compose.yaml ps          # 状态
docker compose -f compose.yaml stop        # 停止（数据保留）
docker compose -f compose.yaml up -d       # 启动（restart 政策自动拉起）
docker compose -f compose.yaml restart superagent
```

面板：`http://127.0.0.1:3082/?token=<容器日志里的 token>`
健康 API：`curl -s -H 'x-orchestrator-request: 1' http://127.0.0.1:3082/orchestrator/api/state`

### 4.2 备份（重要）

```bash
# 备份 = 停服/暂停后打包整个数据目录（含 SQLite、gh 凭据、MySQL 数据）
docker compose -f compose.yaml stop
tar czf ~/dsh-superagent-backup-$(date +%Y%m%d).tar.gz -C ~ dsh-superagent-data
docker compose -f compose.yaml up -d
```

升级前**必须**备份（schema 单向迁移，回滚靠备份）。

### 4.3 升级 super-agent

```bash
git -C /path/to/super-agent pull && cd /path/to/super-agent
pnpm install && pnpm build
docker compose -f compose.yaml up -d --build
```
（若只是容器内 profile 更新，改镜像后重建即可；数据目录不动。）

### 4.4 暂停 / 恢复处理

面板 Settings → 或 `POST /orchestrator/api/executor/pause {"paused":true}`。
暂停只停派活/回复，Source 继续记录事件。

### 4.5 关键状态位置

| 内容 | 位置 |
|---|---|
| 状态库（工单/决策/回复） | `~/dsh-superagent-data/state/orchestrator.sqlite` |
| agent GitHub 登录 | `~/dsh-superagent-data/gh-agent/` |
| DSH profile（模型 key 在 `.credentials.yaml`） | `~/dsh-superagent-data/profile/` |
| MySQL 数据 | `~/dsh-superagent-data/mysql/` |
| 工单工作目录（可再生） | 容器内 `/work/<工单短名>` |

---

## 5. 故障排查（实战踩过的坑）

| 现象 | 原因 | 处理 |
|---|---|---|
| Issue 正文 @ 不触发 | 正文在轮询间隙创建，`created_at < since` 被游标跳过 | **发新评论**（重要：以后一律用评论派活） |
| Eval 一直 `unavailable / timeout` | 主 Session 用的是旧默认模型（不可路由） | 删除主 Session 会话文件后重启，按 `eval.model` 重新播种；或确保首次配置前模型已就位 |
| 宿主打不开 3082 / Empty reply | dsh 只绑容器回环，Docker 发布转发不到 | 镜像内 socat 转发 `3182 → 127.0.0.1:3082`，compose 发布 `3082:3182`（已内置） |
| 容器 `unhealthy` | 健康检查（容器内 127.0.0.1:3082）失败 | 看 `docker logs dsh-superagent`；确认 socat 与 dsh 都在跑 |
| setup `repositoryReadOnly` | agent 对该仓库无 Write | 加协作者（Write）后 `accept-invites.sh` |
| setup `repositoryUnreadable` | 仓库名写错 / 未接受邀请 / 私库无权限 | 核对 `owner/name`，接受邀请 |
| DBeaver 报 RSA 公钥错误 | MySQL 8.4 `caching_sha2_password` + 非 TLS | DBeaver 驱动属性加 `allowPublicKeyRetrieval=true`；CLI 加 `--get-server-public-key` 或 `--ssl-mode=REQUIRED` |
| 工单卡 `person/review` | 等你 review/merge（正常） | 去 PR 上 review/merge |
| 切源后 setup 报错 | 目标仓库不可读/无写权限 | 先加协作者并接受邀请，再切源 |
| `连续 N 次轮询失败… gh: Not Found (HTTP 404)` | 切源后旧仓库的订阅线程仍被轮询（按新仓库读取 404） | 退订旧线程：新版 `switch-repo.sh` 自动做；手动 `POST /threads/<key>/unsubscribe` 或面板 Threads 里退订 |

---

## 6. 安全提醒

- 镜像内**无密钥**；所有密钥在 `~/dsh-superagent-data`（gh 登录、模型 key 凭据引用、mysql.env）
- 端口只发布 `127.0.0.1`：面板 3082、MySQL 13306（DBeaver 用）
- 不要挂 `docker.sock`、不要 `--privileged`、不要把家目录挂进容器
- 仓库权限：**推荐仓库归你（owner）/组织，agent 只拿 Write**；测试仓库归 agent 名下也可，但它是 owner
- 模型 key 走面板配置（存 `.credentials.yaml`），不要写进 `superagent.env`
- 派活与合并：**派活用新评论，合并由人做**（agent 被设计为不自行合并）
