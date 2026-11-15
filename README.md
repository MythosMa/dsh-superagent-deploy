# dsh-superagent-deploy

> **独立部署层**：把 [super-agent](https://github.com/deepseek-ai/dsh-superagent-prototype)（MIT）打包成开箱即用的 Docker 部署。
> 本仓库**不含** super-agent 源码——构建镜像时会从 GitHub 拉取（可指定仓库与 ref）。

## 特性

- 一条命令部署（macOS / Linux / Windows），自动建数据目录、构建、启动、等待就绪
- **版本可钉**：`SUPERAGENT_REPO` / `SUPERAGENT_REF` 指定源码仓库与 commit，保证可复现
- 镜像 = 无密钥、可重建；状态与密钥全部在宿主机数据目录：`~/dsh-superagent-data`
- 可选组件：MySQL（默认不启动）、Go / Flutter（可跳过）、自定义工具链钩子
- 附带完整手册、运维文档、拆工单模板

## 快速开始

**前置**：Docker Desktop（Windows 需 WSL2 后端），内存 ≥ 8GB，网络能访问 GitHub/npm。

> **先记住一件事**：镜像只是可随时重建的部署件，**所有状态与密钥都在宿主机数据目录** `~/dsh-superagent-data`
> （Windows：`%USERPROFILE%\dsh-superagent-data`），由部署脚本自动创建。删掉它 = 模型 key、GitHub 登录、
> 工单历史、MySQL 数据全丢，重建镜像也救不回来。详见下方**「本地数据目录」**（必读）。

```bash
# macOS / Linux / Git-Bash
git clone <本仓库地址> dsh-superagent-deploy
cd dsh-superagent-deploy
bash scripts/setup.sh

# Windows PowerShell
powershell -ExecutionPolicy Bypass -File scripts/setup.ps1
```

首次构建约 10–30 分钟（拉取源码 + 下载依赖）。完成后脚本会打印面板地址与 token。

### 本地数据目录

`compose.yaml` 用 bind mount 把数据目录挂进容器，**容器内不存任何状态**——数据目录才是本体：

| 宿主机（默认 `~/dsh-superagent-data/`） | 容器内 | 内容 | 删掉会怎样 |
|---|---|---|---|
| `profile/` | `/data/dsh` | DSH profile：模型 provider 与 API key（`.credentials.yaml`）、sessions | 要重新配模型、重建 Session |
| `gh-agent/` | `/data/gh-agent` | agent 的 GitHub 登录态 | 要重新 `gh-agent auth login` |
| `state/` | `/data/state` | `orchestrator.sqlite`：工单、决策、回复、轮询游标 | 在途工单与历史全丢 |
| `mysql/` | `/var/lib/mysql` | MySQL 数据（仅 `--with-mysql` 时） | 数据库全丢 |
| `superagent.env`、`mysql.env` | — | 运行时环境变量、MySQL 随机密码（首次生成） | compose 报 `env file ... not found`，服务直接起不来 |

**四条规矩**：

1. **镜像 ≠ 数据**：`docker compose down`、`up -d --build`、`git pull` 都不会动数据目录；只有删目录 / 换路径才会"失忆"，且不可恢复。
   想彻底重来（清空一切）：`docker compose down` → 删除整个数据目录 → 重跑 `setup.sh`。
2. **路径定下来就别改**：要换位置，请在**首次部署前**写进仓库根的 `.env`（`setup` 脚本与 `docker compose` 读同一份）：
   ```bash
   # .env 里写绝对路径；Windows 用正斜杠，如 D:/docker/dsh-superagent-data
   DSA_DATA_DIR=/absolute/path/dsh-superagent-data
   ```
   首次启动后再改，compose 会挂到新的空目录，表现就是"配置全没了"——旧数据其实还在原路径，改回去即可。
3. **别跳过数据目录初始化**：compose 的 `env_file` 指向数据目录里的 `superagent.env` / `mysql.env`，缺这两个文件 `docker compose up` 会直接失败。
   用 `setup.sh`（自带初始化）即可；手动分步时必须先跑 `scripts/init-data.sh`，再 `docker compose up -d`。
4. **升级 / 换机前先备份，密钥不进 git**：`.env` 与数据目录里都是明文密钥（备份命令见 [更新](#更新)，完整说明见 [运维手册](docs/operations.md)）。**不要提交、不要外发。**

> Linux 上容器会把数据目录属主改为 uid 1001（容器内 `dsh` 用户）；删除或打包时提示权限不足，用 `sudo`。

### 可选参数

| 需求 | 用法 |
|---|---|
| 同时启动 MySQL（默认不启动） | `--with-mysql`（Windows：`-WithMysql`） |
| 安装 Go / Flutter（默认不装） | `--with-go --with-flutter`（Windows：`-WithGo -WithFlutter`） |
| 指定源码仓库（你的 fork） | `--repo https://github.com/<you>/<fork>.git`（Windows：`-Repo ...`） |
| 钉源码版本（推荐生产） | `--ref <commit/tag>`（Windows：`-Ref ...`），或写进 `.env` |
| 其他开发环境（Rust/Java/Python 包…） | 编辑 [toolchains/extra.sh](toolchains/extra.sh)，构建时自动执行 |

## 构建参数（也可写在 `.env` 里，见 [.env.example](.env.example)）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SUPERAGENT_REPO` | 上游 prototype | 源码仓库 |
| `SUPERAGENT_REF` | `main` | 分支 / tag / commit |
| `SUPERAGENT_INSTALL_GO` | `0` | `1` 启用 Go（默认不装） |
| `SUPERAGENT_INSTALL_FLUTTER` | `0` | `1` 启用 Flutter（默认不装） |
| `DSA_DATA_DIR` | `~/dsh-superagent-data` | 数据目录；**首次部署前定好，之后别改**（写 `.env` 或 export，见上一节） |

## 兼容性

本部署层依赖 super-agent 的以下约定；跨版本升级时请验证：

| 依赖点 | 说明 |
|---|---|
| `package.json` / `pnpm-lock.yaml` / `src/` | 构建 bundle |
| `cordis.patch.yml` | 作为 DSH bundle 的插件补丁 |
| `examples/profile.cordis.patch.yml` | 首启生成机器配置 |
| `prompts/`、`skills/`、`locale/` | 运行期读取 |
| `engines.dsh` 与面板 API `/orchestrator/api/*` | 镜像内 dsh 版本与面板接口 |

> 推荐：发布部署版本时记录「已测试的 `SUPERAGENT_REF`」，用户按需钉住。

## 更新

```bash
# 部署层更新（本仓库）
git pull
docker compose -f compose.yaml up -d --build

# 源码版本更新（钉到新的 commit）
SUPERAGENT_REF=<new-commit> docker compose -f compose.yaml up -d --build
```

升级前先备份数据目录（**先 stop 再打包**，避免 SQLite 半写）：

```bash
docker compose -f compose.yaml stop
tar czf ~/dsh-superagent-backup-$(date +%Y%m%d).tar.gz -C ~ dsh-superagent-data
docker compose -f compose.yaml up -d
```

自定义过 `DSA_DATA_DIR` 的，把上面两处 `~/dsh-superagent-data` 换成该路径。Windows 用 `Compress-Archive` 代替 `tar`。
不建议用脚本拉取代码——脚本只负责构建与启动。

## 目录结构

```
dsh-superagent-deploy/
├── Dockerfile              # 构建时拉取 super-agent 源码并编译 bundle
├── compose.yaml            # superagent + 可选 mysql（--profile mysql）
├── docker-entrypoint.sh    # 容器入口（首启初始化、端口转发）
├── toolchains/extra.sh     # 自定义工具链钩子
├── scripts/                # setup / init-data / switch-repo / accept-invites / add-instance
├── docs/                   # 部署手册 · 运维手册 · 工单模板
├── mysql.env.example / superagent.env.example / .env.example
└── README.md
```

## 文档

- **[部署手册（从零到运行，macOS/Windows）](docs/manual.md)**
- [运维手册：多仓库、合作者、备份升级、故障排查](docs/operations.md)
- [拆工单模板：Flutter + Go + MySQL](docs/ticket-templates.md)

## License

MIT。super-agent 上游代码在其自身仓库中按 MIT 分发，本仓库仅提供部署层。
