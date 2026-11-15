# super-agent 部署手册（从零到运行）

> 适用：**macOS**（Apple Silicon / Intel）与 **Windows 10/11**（Docker Desktop）。
> 本手册从"拉取仓库"开始，到"agent 在 GitHub 上跑通第一单"结束。
> 所有命令在**项目根目录**执行（本部署仓库根目录）。容器内是 Linux，无需在宿主机装 Node/Go/Flutter。

---

## 0. 前置条件

| 项 | 要求 | 说明 |
|---|---|---|
| Docker | Docker Desktop（macOS/Windows） | Windows 需 WSL2 后端；Docker Engine ≥ 24 |
| 资源 | 内存 **≥ 8GB** 给 Docker | Flutter/Go 构建与运行需要 |
| 磁盘 | ≥ 15GB 可用 | 镜像约 3–5GB + 数据 |
| 网络 | 能访问 npm/GitHub/镜像源 | 首次构建会下载依赖 |
| 架构 | 镜像与机器**同架构** | 本手册默认 arm64（Apple Silicon）构建；x86 机器会构建 x86 镜像 |
| 工具链 | **默认不安装**（镜像最小） | 按需 `--with-go` / `--with-flutter`；其他环境用 `toolchains/extra.sh`（见 2.4） |
| 源码来源 | 构建时从 GitHub 拉取 | `SUPERAGENT_REPO` / `SUPERAGENT_REF`（默认上游 prototype @ main） |

### 0.1 安装 Docker Desktop

- **macOS**：官网下载 Docker Desktop → 安装 → 启动 → Settings → Resources 设内存 ≥8GB
- **Windows**：官网下载 Docker Desktop → 安装时勾选 WSL2 → 启动 → Settings → Resources 设内存 ≥8GB

### 0.2 验证

```bash
# macOS（终端） / Windows（PowerShell）
docker --version
docker compose version
docker info
```

---

## 1. 获取项目

本仓库是**独立的部署层**（不含 super-agent 源码）：构建镜像时会从 GitHub 拉取 super-agent（默认上游 `deepseek-ai/dsh-superagent-prototype`，可用 `SUPERAGENT_REPO`/`SUPERAGENT_REF` 指向你的 fork / 分支 / commit）。

```bash
# macOS / Windows（PowerShell 或 Git Bash 均可）
git clone <本部署仓库地址> dsh-superagent-deploy
cd dsh-superagent-deploy
```

目录速览：

```
dsh-superagent-deploy/            # 本仓库 = 部署层
├── Dockerfile                 # 构建时拉取 super-agent 源码并编译 bundle
├── compose.yaml               # superagent + 可选 mysql（--profile mysql）
├── docker-entrypoint.sh       # 容器入口（首启建 profile、socat 端口转发）
├── toolchains/extra.sh        # 自定义工具链钩子（可选）
├── mysql.env.example          # MySQL 密钥模板
├── superagent.env.example     # 运行时可选环境
├── .env.example               # 可选：DSA_DATA_DIR / SUPERAGENT_REPO / SUPERAGENT_REF
├── scripts/
│   ├── setup.sh / setup.ps1        # 一键部署
│   ├── init-data.sh / init-data.ps1# 数据目录初始化
│   ├── switch-repo.sh              # 一条命令切仓库
│   ├── accept-invites.sh           # 接受仓库协作邀请
│   └── add-instance.sh             # 第二实例（多仓库并行）
└── docs/                       # 本手册、运维手册、工单模板
```

> **关于源码来源**：默认拉取上游 prototype 的 `main`。生产使用建议钉 commit：
> `SUPERAGENT_REF=<commit> bash scripts/setup.sh`，或写进 `.env`。

---

## 2. 部署（二选一）

### 2.1 一键部署（推荐）

**macOS / Linux / Git-Bash：**
```bash
bash scripts/setup.sh
```

**Windows（PowerShell）：**
```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup.ps1
```

**可选参数**：`--with-mysql`（启用 MySQL）、`--with-go`、`--with-flutter`、`--repo URL`（源码仓库）、`--ref REF`（分支/tag/commit）；Windows 对应 `-WithMysql`、`-WithGo`、`-WithFlutter`、`-Repo`、`-Ref`。

脚本自动完成：检查 Docker → 建数据目录（含随机密码 mysql.env）→ 构建镜像 → 启动容器 → 等待健康 → 打印面板地址与 token。

> 首次构建需 10–30 分钟（下载 Flutter SDK 等），请耐心等待；失败时脚本会打印检查命令。

### 2.2 手动分步（等价，便于排错）

```bash
# ① 初始化数据目录（mac）
bash scripts/init-data.sh
#    Windows：
#    powershell -ExecutionPolicy Bypass -File scripts/init-data.ps1

# ② 构建镜像（可选：SUPERAGENT_INSTALL_GO=1 / SUPERAGENT_INSTALL_FLUTTER=1 启用工具链；默认都不装）
docker compose -f compose.yaml build

# ③ 启动（需要 MySQL 时加 --profile mysql）
docker compose -f compose.yaml up -d
# docker compose -f compose.yaml --profile mysql up -d

# ④ 看状态
docker compose -f compose.yaml ps
docker logs --tail 20 dsh-superagent
```

**Windows 注意**：compose 默认路径使用 `${HOME}`，Windows 上建议**用 setup.ps1**（它会设置 `DSA_DATA_DIR`）；手动执行时先设：
```powershell
$env:DSA_DATA_DIR = "$env:USERPROFILE\dsh-superagent-data"
```

### 2.3 部署成功的标志

```bash
docker compose -f compose.yaml ps
# dsh-superagent          Up (healthy)
# dsh-superagent-mysql    Up (healthy)
```
面板可访问（浏览器打开）：
```
http://127.0.0.1:3082/?token=<docker logs dsh-superagent 里打印的 token>
```
健康 API：
```bash
curl -s -H 'x-orchestrator-request: 1' http://127.0.0.1:3082/orchestrator/api/state
```

### 2.4 可选组件与自定义工具链（默认最小安装）

镜像默认只装 super-agent 运行必需：`node / pnpm / git / tmux / python3 / gh / dsh / bundle`。
以下组件**默认不安装**，按需启用：

**MySQL（独立容器，不装进镜像）**
```bash
bash scripts/setup.sh --with-mysql        # Windows: -WithMysql
# 已部署后单独启动：
docker compose -f compose.yaml --profile mysql up -d
```
连接：`127.0.0.1:13306`，账号密码见 `~/dsh-superagent-data/mysql.env`；数据在 `~/dsh-superagent-data/mysql`。

**Go**
```bash
bash scripts/setup.sh --with-go           # Windows: -WithGo
# 或手动：SUPERAGENT_INSTALL_GO=1 docker compose -f compose.yaml build
```
版本：`Dockerfile` 的 `GO_VERSION`（默认 1.23.4）。

**Flutter**
```bash
bash scripts/setup.sh --with-flutter      # Windows: -WithFlutter
```
版本：`FLUTTER_TAG`（建议钉具体版本，如 3.27.1）。

**其他工具链（Rust / Java / Python 包 / CLI）**
编辑 [`toolchains/extra.sh`](../toolchains/extra.sh)，构建时以 root 自动执行，例如：
```sh
apt-get update && apt-get install -y --no-install-recommends rustc cargo openjdk-17-jdk
python3 -m pip install --break-system-packages <package>
```
> 只写安装步骤，不要放密钥。

**生效方式**：改动后重新构建并启动
```bash
docker compose -f compose.yaml up -d --build
```

- 需要给 worker 提供数据库连接时，在面板 Execution 的执行环境变量里配置（见 [ticket-templates.md](ticket-templates.md) 的 MySQL 部分）。

---

## 3. 首次配置（必做）

> 顺序很重要：**先配模型，再登录 GitHub，再配 Sources/Policy/Executor**。

### 3.1 打开面板

浏览器打开 `http://127.0.0.1:3082/?token=...`（token 见 `docker logs dsh-superagent`）。
左侧会看到 **Superagent** 入口；顶部 **Settings（设置）** 是 DSH 级配置。

### 3.2 配置模型 provider 与 API key

在面板 **Settings → 模型/Models（Providers）** 里新增一个 provider：

| 字段 | 示例 |
|---|---|
| Provider 类型 | DeepSeek 官方 / Anthropic 兼容 / OpenAI 兼容（按你的服务商） |
| Base URL | 你的服务商 API 地址（如 `https://llm.example.com`） |
| 模型 | 如 `deepseek-v4.1-flash-1017`（以服务商为准） |
| API Key | 你的 key（保存后存入 `profile/.credentials.yaml`） |

保存后确认 `GET /orchestrator/api/models` 有该 provider、`failures: []`。

> **重要**：super-agent 的 **Eval 与 Executor 角色模型**默认取 profile 默认模型；若默认模型不可路由，
> 请在 Superagent → Settings 里把 **Eval 模型 / Executor 模型**显式设为你刚配的 `provider/model`。
> 若先启动了服务、后补的模型配置，主 Session 可能已用旧默认模型创建——见「故障排查」。

### 3.3 登录 agent 的 GitHub 账号（device flow）

准备一个**专用 agent 账号**（推荐，不与个人账号混用），并在目标仓库给它 **Write** 权限。

```bash
# macOS / Windows（PowerShell）都在宿主机执行
docker exec -it dsh-superagent gh-agent auth login
# 选择：GitHub.com → HTTPS → 出现 code → 浏览器打开 https://github.com/login/device
# 输入 code → 用 agent 账号授权
```

验证：
```bash
docker exec dsh-superagent gh-agent api user --jq .login     # 输出 agent 账号名
docker exec dsh-superagent gh-agent auth status              # 显示已登录
```
凭据写入数据目录 `~/dsh-superagent-data/gh-agent/`（容器重建不丢）。

### 3.4 配置 Sources（GitHub）

Superagent → **Sources → GitHub**：

| 字段 | 值 |
|---|---|
| enabled | ✅ |
| repository | `owner/name`（agent 有 Write 的仓库） |
| cli | `/usr/local/bin/gh-agent` |
| 其余（pollSeconds 等） | 保持默认 |

保存后会自动跑 setup 检查（读仓库、验 push 权限）并重启服务；面板 Overview 应显示 **setup 无缺项**、Sources state = `ready`。

### 3.5 配置 Policy（谁可以派活）

Superagent → **Policy**：

```json
{
  "rules": [ ...保持默认... ],
  "sources": { "github": { "allowed": [ { "id": "<你的 GitHub 登录名>" } ] } }
}
```

- `allowed`：允许派活的账号（只放你自己，先跑通再扩）
- 接收模式：**observe**（推断类工作只记录不执行；显式 @ 请求照常处理）

### 3.6 配置 Executor（工作目录与准备命令）

Superagent → **Settings → Executor**：

| 字段 | 值 |
|---|---|
| directory | `/work`（容器内工作根，可再生产物，不占本地备份） |
| prepare | `[ -d "$DSH_SUPERAGENT_DIR/.git" ] || git clone --depth 1 "https://github.com/$DSH_SUPERAGENT_GITHUB_REPOSITORY.git" "$DSH_SUPERAGENT_DIR"` |
| maxWorkers | 3（按机器调整） |

> 如果仓库较大、想用 worktree 加速，可换成文档中的 fetch+worktree 模板。

### 3.7 配置 Prompts（团队约定，可选）

Superagent → **Prompts**：写团队段落，例如：
- 「PR 正文必须包含：这是自动 agent 而非人工」
- 「提交作者使用 agent 账号」
- 「不要自行合并 PR」/「自动合并条件：…」

---

## 4. 验收：跑通第一单

1. 用**你的个人账号**（在 allowed 名单里）到目标仓库：
   - 新建 Issue（或对新评论）内容包含 `@<agent账号> <请求>`
   - ⚠️ **必须是新 Issue 或新评论**；编辑已有正文不会触发
2. 等 ≤60 秒（Source 轮询间隔）：面板 **Overview** 出现 Ticket
3. agent 自动：ack → 在 `/work` clone → 写代码 → 推 `agent/<短名>` 分支 → 开 PR
4. 你在 PR 上 review → **merge**（合并由人做，agent 不自行合并）
5. merge 后 Issue 自动关闭，工单以 `merged` 结束

验收清单：
- [ ] 面板 Superagent 可打开，Overview 无 setup 缺项
- [ ] Sources → GitHub state = `ready`
- [ ] `gh-agent api user` 返回 agent 账号
- [ ] `GET /orchestrator/api/models` 有可用 provider
- [ ] Issue 评论 @agent 后 1–2 分钟内出现 Ticket
- [ ] 出现 PR，且 diff 只含本次请求范围

---

## 5. 日常运维

```bash
# 启停（数据目录保留）
docker compose -f compose.yaml stop
docker compose -f compose.yaml up -d
docker compose -f compose.yaml restart superagent
docker compose -f compose.yaml ps

# 健康
curl -s -H 'x-orchestrator-request: 1' http://127.0.0.1:3082/orchestrator/api/state
docker logs -f dsh-superagent

# 备份（升级前必做）
docker compose -f compose.yaml stop
tar czf ~/superagent-backup-$(date +%Y%m%d).tar.gz -C ~ dsh-superagent-data
docker compose -f compose.yaml up -d

# 升级
git pull && docker compose -f compose.yaml up -d --build
```

### 5.1 切仓库（一条命令）

```bash
scripts/switch-repo.sh owner/name      # 默认备份并清理旧仓库历史
scripts/switch-repo.sh owner/name --keep-history
```

### 5.2 让 agent 加入你的仓库（你是 owner）

```
① 你创建仓库 → Settings → Collaborators → Add <agent-account> → Write
② scripts/accept-invites.sh        # agent 接受邀请
③ scripts/switch-repo.sh 你的账号/仓库名
④ 在你的仓库 Issue 里发新评论 @agent
```

### 5.3 多仓库并行（第二实例）

```bash
scripts/add-instance.sh b 3083 13307
docker compose -f instance-b/compose.yaml up -d
DSH_SUPERAGENT_URL=http://127.0.0.1:3083 scripts/switch-repo.sh owner/repo-b
```

### 5.4 更新部署层与源码版本

**部署层更新（本仓库）**：

```bash
git pull
docker compose -f compose.yaml up -d --build
```

**源码版本更新**（钉到新的 super-agent commit/tag）：

```bash
SUPERAGENT_REF=<new-commit> docker compose -f compose.yaml up -d --build
# 或写进 .env：SUPERAGENT_REF=<new-commit>
```

- 升级前备份 `~/dsh-superagent-data`（或 `DSA_DATA_DIR` 指向的位置）。
- 不建议用脚本拉代码——脚本只负责构建与启动。

---

## 6. 换机迁移

**前提：同架构**（arm64 → arm64；x86 → 需要在新机重新 build）。

```bash
# 旧机
docker save dsh-superagent:local | gzip > superagent-img.tar.gz
docker compose -f compose.yaml stop
tar czf superagent-data.tar.gz -C ~ dsh-superagent-data
docker compose -f compose.yaml up -d

# 新机
docker load < superagent-img.tar.gz
# 解压 superagent-data.tar.gz 到 ~/（或设 DSA_DATA_DIR 指向它）
cd dsh-superagent-deploy && docker compose -f compose.yaml up -d
```

数据目录含：profile（模型 key）、gh-agent（登录）、state（工作历史）、mysql（数据库）。
路径不同时：`DSA_DATA_DIR=/path/to/dsh-superagent-data docker compose -f compose.yaml up -d`。

---

## 7. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 首次构建卡住/失败 | 网络慢（npm/GitHub/Flutter） | 重试；必要时配 npm 镜像/代理后重建 |
| 容器 `unhealthy` | 内部健康检查失败 | `docker logs dsh-superagent`；确认 dsh 与 socat 在跑 |
| 面板打不开 / Empty reply | 宿主无法连容器 | 镜像内 socat 已内置（3182→127.0.0.1:3082），确认 compose 端口是 `3082:3182` |
| setup 报 `repositoryUnset` | 没填仓库 | Sources → repository 填 `owner/name` |
| setup 报 `repositoryReadOnly` | agent 无 Write | 加协作者（Write）后 `accept-invites.sh` |
| setup 报 `repositoryUnreadable` | 仓库错/邀请未接受 | 核对名称、接受邀请 |
| 评论 @agent 后没反应 | 编辑了正文/轮询未到 | 发**新评论**，等 60 秒 |
| Eval 一直 `unavailable/timeout` | 主 Session 用了不可路由的默认模型 | 显式设 Eval/Executor 模型；或重建主 Session（见下） |
| 切源后 `github: Not Found 404` | 旧仓库订阅线程被按新仓库轮询 | `switch-repo.sh` 已自动清理；手动 `POST /threads/<key>/unsubscribe` |
| DBeaver 连 MySQL 报 RSA 公钥错误 | MySQL 8.4 `caching_sha2_password` | 驱动属性加 `allowPublicKeyRetrieval=true` |
| Windows 上 compose 路径为空 | `HOME` 未设置 | 用 `setup.ps1` 或设置 `DSA_DATA_DIR`（正斜杠路径） |
| 升级后"配置全没了" | 改过 `DSA_DATA_DIR`，compose 挂到了新空目录 | 改回原路径；旧数据仍在原目录（路径必须前后一致，写进 `.env`） |
| `docker compose up` 报 `env file ... not found` | 没初始化数据目录（缺 `superagent.env` / `mysql.env`） | 先跑 `scripts/init-data.sh`，或用 `setup.sh` |
| Linux 上备份/删除数据目录报权限不足 | 容器把属主改成 uid 1001（`dsh`） | 用 `sudo`，或先 `docker compose down` 再操作 |

**重建主 Session（模型配晚了的补救）**：
```bash
# 停服务 → 删除主 Session 会话文件 → 启动（会按当前 eval.model 重新播种）
docker compose -f compose.yaml stop superagent
rm -rf ~/dsh-superagent-data/profile/sessions/--data-state--/orchestrator-*
docker compose -f compose.yaml start superagent
```

---

## 8. 安全清单

- 镜像内**无密钥**；密钥全在 `~/dsh-superagent-data`（gh 登录、模型 key、mysql.env）
- 端口只发布 `127.0.0.1`；不挂 `docker.sock`、不用 `--privileged`、非 root 运行
- agent 用**专用 GitHub 账号**；正式仓库**归你/组织所有，agent 只拿 Write**
- 派活用新评论；**合并始终由人完成**
- 备用：需要更高隔离时，把该容器跑在独立用户/独立机器上

---

## 附录 A：命令速查（macOS / Windows 对照）

| 操作 | macOS / Git-Bash | Windows PowerShell |
|---|---|---|
| 一键部署 | `bash scripts/setup.sh` | `powershell -ExecutionPolicy Bypass -File scripts/setup.ps1` |
| 一键部署（含 MySQL） | `bash scripts/setup.sh --with-mysql` | `... setup.ps1 -WithMysql` |
| 启用 Go/Flutter | `--with-go --with-flutter` | `-WithGo -WithFlutter` |
| 初始化数据目录 | `bash scripts/init-data.sh` | `powershell -File scripts/init-data.ps1` |
| 构建 | `docker compose -f compose.yaml build` | 同左 |
| 启动 | `docker compose -f compose.yaml up -d` | 同左 |
| 启动（含 MySQL） | `docker compose -f compose.yaml --profile mysql up -d` | 同左 |
| 状态 | `docker compose -f compose.yaml ps` | 同左 |
| 日志 | `docker logs -f dsh-superagent` | 同左 |
| gh 登录 | `docker exec -it dsh-superagent gh-agent auth login` | 同左 |
| 数据目录 | `~/dsh-superagent-data` | `%USERPROFILE%\dsh-superagent-data` |
| 更新 | `git pull && docker compose -f compose.yaml up -d --build` | 同左 |
| 健康检查 | `curl -s -H 'x-orchestrator-request: 1' http://127.0.0.1:3082/orchestrator/api/state` | `Invoke-WebRequest -Uri http://127.0.0.1:3082/orchestrator/api/state -Headers @{'x-orchestrator-request'='1'}` |

## 附录 B：相关文档

- [README.md](../README.md) —— 部署件说明
- [docs/operations.md](operations.md) —— 多仓库、合作者、备份升级、故障排查
- [docs/ticket-templates.md](ticket-templates.md) —— Flutter + Go + MySQL 拆工单模板
- [toolchains/extra.sh](../toolchains/extra.sh) —— 自定义工具链钩子
- [CONTRIBUTING.md](../../CONTRIBUTING.md) —— 参与贡献
