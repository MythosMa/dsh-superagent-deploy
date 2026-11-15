#!/usr/bin/env bash
# ===========================================================================
# 一条命令把 super-agent 切换到另一个 GitHub 仓库
#
#   用法: scripts/switch-repo.sh owner/name [--keep-history]
#         scripts/switch-repo.sh https://github.com/owner/name.git
#
# 默认行为（推荐）：
#   1. 更新 source:github 的 repository（保留 cli 等其余配置）
#   2. 保存触发重启，等待 runtime=ready + setup=null + accounts.repository 匹配
#   3. 退订旧仓库的订阅线程（避免按新仓库轮询旧线程 404）
#   4. 备份并清理旧仓库的本地历史：thread/trigger/trigger_thread/disposition/
#      ticket/decision/effect/outbox + 每线程游标（github-cursor:*、github-ci:*、
#      github-retry、thread-*）——避免“线程 key 跨仓库复用”的脏数据
#   5. 重启容器并再次等待就绪
#
#   --keep-history：只执行 1-3，保留本地历史（旧数据可能与新仓库同号线程混淆）
#
# 环境变量：
#   DSH_SUPERAGENT_URL         （默认 http://127.0.0.1:3082）
#   DSH_SUPERAGENT_STATE_DIR   （默认 ~/dsh-superagent-data/state）
#   DSH_SUPERAGENT_CONTAINER   （默认 dsh-superagent）
# ===========================================================================
set -euo pipefail

REPO=""
KEEP_HISTORY=0
for arg in "$@"; do
  case "$arg" in
    --keep-history) KEEP_HISTORY=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) REPO="$arg" ;;
  esac
done
[ -n "$REPO" ] || { echo "用法: $0 owner/name [--keep-history]" >&2; exit 1; }

URL="${DSH_SUPERAGENT_URL:-http://127.0.0.1:3082}"
API="$URL/orchestrator/api"
STATE_DIR="${DSH_SUPERAGENT_STATE_DIR:-$HOME/dsh-superagent-data/state}"
CONTAINER="${DSH_SUPERAGENT_CONTAINER:-dsh-superagent}"
DB="$STATE_DIR/orchestrator.sqlite"

REPO="$(python3 - "$REPO" <<'PY'
import re, sys
s = sys.argv[1].strip()
m = re.search(r'github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$', s)
print(f"{m.group(1)}/{m.group(2)}" if m else s)
PY
)"

echo "== 切换 source:github -> $REPO =="

# ---- 1. 切源 + 等待就绪 + 退订旧线程 ----
python3 - "$REPO" "$API" <<'PY'
import json, sys, time, urllib.request, urllib.error, urllib.parse

repo, api = sys.argv[1], sys.argv[2]
H = {'x-orchestrator-request': '1', 'content-type': 'application/json'}

def get(path):
    return json.load(urllib.request.urlopen(urllib.request.Request(api + path, headers={'x-orchestrator-request': '1'}), timeout=15))

def put(path, body):
    req = urllib.request.Request(api + path, data=json.dumps(body).encode(), headers=H, method='PUT')
    return json.load(urllib.request.urlopen(req, timeout=60))

def wait_ready():
    deadline = time.time() + 180
    while time.time() < deadline:
        time.sleep(2)
        try:
            st = get('/state')
        except Exception:
            continue
        rt = st['health']['runtime']['state']
        problem = st['setup'].get('problem')
        accounts = (st['setup'].get('accounts') or {}).get('repository')
        if rt == 'ready' and problem is None and accounts == repo:
            print(f'OK: runtime=ready, setup=null, accounts.repository={accounts}')
            return True
        if rt == 'paused' and problem is not None:
            print('SETUP 缺项:', json.dumps(problem, ensure_ascii=False))
            return False
    print('超时：服务未在 180s 内就绪')
    return False

s = get('/settings')
src = next(x for x in s['sources'] if x['id'] == 'github')
value = dict(src['value'])
value['enabled'] = True
cfg = dict(value.get('config') or {})
cfg['repository'] = repo
value['config'] = cfg
try:
    r = put('/settings/source:github', {'value': value, 'revision': src['revision']})
    print('保存结果:', json.dumps(r, ensure_ascii=False)[:300])
except urllib.error.HTTPError as e:
    print('保存失败 HTTP', e.code, e.read().decode()[:400])
    sys.exit(1)

if not wait_ready():
    sys.exit(1)

# 退订旧仓库遗留的订阅线程（--keep-history 时尤其必要）
try:
    tl = get('/threads?filter=subscribed')
    for t in tl.get('items', []):
        key = t.get('key')
        if not key:
            continue
        try:
            req = urllib.request.Request(
                api + '/threads/' + urllib.parse.quote(key, safe='') + '/unsubscribe',
                data=b'', headers=H, method='POST')
            urllib.request.urlopen(req, timeout=15)
            print(f'已退订旧线程: {key}')
        except Exception as e:
            print(f'退订 {key} 失败: {e}')
except Exception as e:
    print('列出线程失败:', e)
PY

# ---- 2. 清理旧仓库历史（默认；--keep-history 跳过）----
if [ "$KEEP_HISTORY" -eq 0 ]; then
  if [ ! -f "$DB" ]; then
    echo "== 警告：状态库不存在（$DB），跳过历史清理 =="
  else
    BAK_DIR="$(dirname "$DB")/backups"
    mkdir -p "$BAK_DIR"
    STAMP="$(date +%Y%m%d-%H%M%S)"
    cp "$DB" "$BAK_DIR/orchestrator-switch-$STAMP.sqlite"
    [ -f "$DB-wal" ] && cp "$DB-wal" "$BAK_DIR/orchestrator-switch-$STAMP.sqlite-wal" || true
    echo "== 已备份状态库到 $BAK_DIR/orchestrator-switch-$STAMP.sqlite =="

    echo "== 停止容器以安全清理 =="
    docker stop "$CONTAINER" >/dev/null 2>&1 || true

    echo "== 清理旧仓库历史（thread/trigger/ticket/decision/effect/outbox + 每线程游标）=="
    sqlite3 "$DB" "
      delete from trigger;
      delete from trigger_thread;
      delete from disposition;
      delete from thread;
      delete from ticket;
      delete from decision;
      delete from effect;
      delete from outbox;
      delete from kv where key like 'github-cursor:%'
        or key like 'github-ci:%'
        or key = 'github-retry'
        or key like 'thread-%';
    "

    echo "== 启动容器 =="
    docker start "$CONTAINER" >/dev/null 2>&1 || true

    # 再次等待就绪
    python3 - "$REPO" "$API" <<'PY'
import json, sys, time, urllib.request
repo, api = sys.argv[1], sys.argv[2]
def get(path):
    return json.load(urllib.request.urlopen(urllib.request.Request(api + path, headers={'x-orchestrator-request': '1'}), timeout=15))
deadline = time.time() + 180
while time.time() < deadline:
    time.sleep(2)
    try:
        st = get('/state')
    except Exception:
        continue
    rt = st['health']['runtime']['state']
    problem = st['setup'].get('problem')
    accounts = (st['setup'].get('accounts') or {}).get('repository')
    if rt == 'ready' and problem is None and accounts == repo:
        print(f'OK: 清理后 runtime=ready, accounts.repository={accounts}')
        sys.exit(0)
    if rt == 'paused' and problem is not None:
        print('SETUP 缺项:', json.dumps(problem, ensure_ascii=False))
        sys.exit(2)
print('超时：清理后服务未在 180s 内就绪')
sys.exit(3)
PY
  fi
else
  echo "== --keep-history：保留本地历史（旧线程可能与新仓库同号冲突）=="
fi

echo "== 完成：source:github = $REPO =="
