#!/usr/bin/env bash
# ===========================================================================
# 创建第二个（或更多）super-agent 实例，用于多仓库并行（每个实例绑一个仓库）
#   用法: scripts/add-instance.sh <名字> [面板端口=3083] [MySQL端口=13307]
#   例:   scripts/add-instance.sh b 3083 13307
# 说明：
#   - 复用已构建镜像 dsh-superagent:local（不需要重新 build）
#   - 独立数据目录 ~/dsh-superagent-data-<名字>（profile/state/mysql 全独立）
#   - 复制现有 gh-agent 登录凭据（同一 agent 账号）
#   - 容器内端口不变（3182→3082），只改宿主发布端口
# ===========================================================================
set -euo pipefail

NAME="${1:-}"
[ -n "$NAME" ] || { echo "用法: $0 <名字> [面板端口=3083] [MySQL端口=13307]" >&2; exit 1; }
PORT="${2:-3083}"
MPORT="${3:-13307}"
DIR="instance-$NAME"
DATA="$HOME/dsh-superagent-data-$NAME"
BASE="$HOME/dsh-superagent-data"

mkdir -p "$DIR" "$DATA"/{profile,gh-agent,state,mysql}
chmod 700 "$DATA" "$DATA"/{profile,gh-agent,state,mysql}

# ---- MySQL 凭据 ----
if [ ! -f "$DATA/mysql.env" ]; then
  RPW="$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)"
  WPW="$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)"
  cat > "$DATA/mysql.env" <<EOF
MYSQL_ROOT_PASSWORD=$RPW
MYSQL_DATABASE=super_agent_test
MYSQL_USER=sa_worker
MYSQL_PASSWORD=$WPW
EOF
  chmod 600 "$DATA/mysql.env"
  echo "[add-instance] 已生成 $DATA/mysql.env（随机密码）"
fi
: > "$DATA/superagent.env"

# ---- 复用 agent 的 gh 登录 ----
if [ -f "$BASE/gh-agent/hosts.yml" ] && [ ! -f "$DATA/gh-agent/hosts.yml" ]; then
  cp -p "$BASE/gh-agent/"* "$DATA/gh-agent/" 2>/dev/null || true
  chmod 600 "$DATA/gh-agent/"* 2>/dev/null || true
  echo "[add-instance] 已复制 gh-agent 登录凭据"
fi

# ---- 生成 compose.yaml ----
cat > "$DIR/compose.yaml" <<EOF
name: dsh-superagent-$NAME

services:
  superagent:
    image: dsh-superagent:local
    container_name: dsh-superagent-$NAME
    restart: unless-stopped
    init: true
    ports:
      - "127.0.0.1:$PORT:3182"
    volumes:
      - $DATA/profile:/data/dsh
      - $DATA/gh-agent:/data/gh-agent
      - $DATA/state:/data/state
    environment:
      DSH_HOME: /data/dsh
      GH_CONFIG_DIR: /data/gh-agent
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy
    mem_limit: 4g
    cpus: 4
    healthcheck:
      test: ["CMD", "curl", "-sf", "-H", "x-orchestrator-request: 1", "http://127.0.0.1:3082/orchestrator/api/state"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 120s

  mysql:
    image: mysql:8.4
    container_name: dsh-superagent-$NAME-mysql
    restart: unless-stopped
    ports:
      - "127.0.0.1:$MPORT:3306"
    volumes:
      - $DATA/mysql:/var/lib/mysql
    env_file:
      - $DATA/mysql.env
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_0900_ai_ci
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\$\$MYSQL_ROOT_PASSWORD --silent"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 60s
    mem_limit: 1g
    cpus: 2
EOF

cat <<EOF

实例已创建：$DIR/compose.yaml
  面板端口：127.0.0.1:$PORT → 容器 3182（内部 3082）
  MySQL 端口：127.0.0.1:$MPORT
  数据目录：$DATA

启动：
  docker compose -f $DIR/compose.yaml up -d

首次启动后（约 1 分钟，容器日志里找 token）：
  http://127.0.0.1:$PORT/?token=<token>

然后配置该实例的 source:github（仓库）与 policy（允许名单），
或直接用：DSH_SUPERAGENT_URL=http://127.0.0.1:$PORT scripts/switch-repo.sh owner/name
EOF
