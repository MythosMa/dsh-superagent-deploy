#!/usr/bin/env bash
# ===========================================================================
# super-agent 一键部署（独立部署仓库）
#
#   用法: bash scripts/setup.sh [选项]
#     --with-mysql     同时启动 MySQL（默认不启动，super-agent 本身不需要它）
#     --with-go        安装 Go 工具链（默认不装）
#     --with-flutter   安装 Flutter SDK（默认不装）
#     --repo URL       源码仓库（默认上游 prototype）
#     --ref REF        源码分支/tag/commit（默认 main；生产建议钉 commit）
#   环境变量: DSA_DATA_DIR（默认 ~/dsh-superagent-data）
#
# 流程：检查 Docker → 初始化数据目录 → 构建镜像（构建时拉取源码）→ 启动 → 等待就绪
# ===========================================================================
set -euo pipefail

WITH_MYSQL=0
INSTALL_GO=0
INSTALL_FLUTTER=0
SUPERAGENT_REPO="${SUPERAGENT_REPO:-}"
SUPERAGENT_REF="${SUPERAGENT_REF:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-mysql) WITH_MYSQL=1; shift ;;
    --with-go) INSTALL_GO=1; shift ;;
    --with-flutter) INSTALL_FLUTTER=1; shift ;;
    --repo) SUPERAGENT_REPO="${2:?--repo 需要 URL}"; shift 2 ;;
    --ref) SUPERAGENT_REF="${2:?--ref 需要 REF}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（见 --help）" >&2; exit 1 ;;
  esac
done
export SUPERAGENT_INSTALL_GO="$INSTALL_GO" SUPERAGENT_INSTALL_FLUTTER="$INSTALL_FLUTTER"
[ -n "$SUPERAGENT_REPO" ] && export SUPERAGENT_REPO
[ -n "$SUPERAGENT_REF" ] && export SUPERAGENT_REF

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
COMPOSE="$ROOT/compose.yaml"

# DSA_DATA_DIR 与 docker compose 共用仓库根的 .env：环境变量 > .env > 默认值。
# 两者必须指向同一目录，否则 compose 的 env_file 会指向一个没初始化过的路径（报 env file not found）。
if [ -z "${DSA_DATA_DIR:-}" ] && [ -f "$ROOT/.env" ]; then
  DSA_DATA_DIR="$(sed -n 's/^[[:space:]]*DSA_DATA_DIR[[:space:]]*=[[:space:]]*//p' "$ROOT/.env" \
    | tail -n 1 | tr -d '\r' \
    | sed -e 's/[[:space:]]#.*$//' \
          -e 's/^"\(.*\)"[[:space:]]*$/\1/' -e "s/^'\(.*\)'[[:space:]]*$/\1/" \
          -e 's/[[:space:]]*$//')"
fi
DATA_DIR="${DSA_DATA_DIR:-$HOME/dsh-superagent-data}"
export DSA_DATA_DIR="$DATA_DIR"

echo "== 1/5 检查 Docker =="
command -v docker >/dev/null || { echo "未找到 docker，请先安装 Docker Desktop"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "未找到 docker compose 插件（请升级 Docker Desktop）"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker 未运行，请先启动 Docker Desktop"; exit 1; }

echo "== 2/5 初始化数据目录: $DATA_DIR =="
bash "$ROOT/scripts/init-data.sh" "$DATA_DIR"

echo "== 3/5 构建镜像（首次会拉取源码并下载依赖，约 10-30 分钟）=="
echo "   源码：${SUPERAGENT_REPO:-<默认上游>} @ ${SUPERAGENT_REF:-main}"
echo "   工具链：Go=$INSTALL_GO  Flutter=$INSTALL_FLUTTER"
docker compose -f "$COMPOSE" build

echo "== 4/5 启动容器 =="
if [ "$WITH_MYSQL" = "1" ]; then
  docker compose -f "$COMPOSE" --profile mysql up -d
else
  docker compose -f "$COMPOSE" up -d
fi

echo "== 5/5 等待服务就绪 =="
OK=0
for i in $(seq 1 90); do
  sleep 2
  CODE="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H 'x-orchestrator-request: 1' 'http://127.0.0.1:3082/orchestrator/api/state' 2>/dev/null || true)"
  if [ "$CODE" = "200" ]; then OK=1; break; fi
done
[ "$OK" = "1" ] || { echo "等待超时：请检查 docker logs dsh-superagent"; exit 1; }

TOKEN="$(docker logs dsh-superagent 2>&1 | grep -o 'http://127.0.0.1:3082/?token=[A-Za-z0-9_-]*' | tail -1 || true)"

cat <<EOF

================ 部署完成 ================
面板:   http://127.0.0.1:3082/
${TOKEN:+Token:  $TOKEN}
$( [ "$WITH_MYSQL" = "1" ] && echo "MySQL:  127.0.0.1:13306  （账号密码见 $DATA_DIR/mysql.env）" )

下一步（首次必做）：
  1) 浏览器打开上面的面板，配置模型 provider 与 API key
  2) docker exec -it dsh-superagent gh-agent auth login   # 登录 agent 的 GitHub 账号（device flow）
  3) 面板 Superagent → Sources：填仓库 owner/name 与 CLI /usr/local/bin/gh-agent
     Policy：允许名单填你的 GitHub 登录名；Executor：directory=/work + prepare 命令
  4) 在仓库 Issue 里发新评论 @<agent账号> 派活
==========================================
EOF
