#!/usr/bin/env bash
# ===========================================================================
# 宿主机侧数据目录初始化（阶段 2）
# 用法：bash scripts/init-data.sh [数据目录]
#   - 默认数据目录：$HOME/dsh-superagent-data（可用 DSA_DATA_DIR 或参数覆盖）
#   - 创建 5 个子目录：profile / gh-agent / state / mysql / storaged 预留
#   - 若 mysql.env 不存在则自动生成随机密码；superagent.env 生成空模板
# 安全：目录权限 700；mysql.env 权限 600；脚本不含任何真实密钥
# ===========================================================================
set -euo pipefail

DATA_DIR="${1:-${DSA_DATA_DIR:-$HOME/dsh-superagent-data}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$DATA_DIR"/{profile,gh-agent,state,mysql}
chmod 700 "$DATA_DIR"
chmod 700 "$DATA_DIR"/{profile,gh-agent,state,mysql}

# ---- mysql.env：不存在则用 openssl 生成强随机密码 ----
if [ ! -f "$DATA_DIR/mysql.env" ]; then
  ROOT_PW="$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)"
  WORKER_PW="$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)"
  cat > "$DATA_DIR/mysql.env" <<EOF
# 由 scripts/init-data.sh 生成
MYSQL_ROOT_PASSWORD=$ROOT_PW
MYSQL_DATABASE=super_agent_test
MYSQL_USER=sa_worker
MYSQL_PASSWORD=$WORKER_PW
EOF
  chmod 600 "$DATA_DIR/mysql.env"
  echo "[init-data] mysql.env 已生成（随机密码）→ $DATA_DIR/mysql.env"
else
  echo "[init-data] mysql.env 已存在，跳过"
fi

# ---- superagent.env：空模板 ----
if [ ! -f "$DATA_DIR/superagent.env" ]; then
  touch "$DATA_DIR/superagent.env"
  chmod 600 "$DATA_DIR/superagent.env"
  echo "[init-data] superagent.env 已生成（空模板）"
else
  echo "[init-data] superagent.env 已存在，跳过"
fi

echo
echo "==== 数据目录就绪：$DATA_DIR ===="
echo "  面板:   http://127.0.0.1:3082"
echo "  MySQL:  127.0.0.1:13306  (DBeaver 用)"
echo "  下一步: docker compose -f compose.yaml up -d --build"
echo "  (记住 mysql.env 里的密码，DBeaver 登录要用)"