#!/usr/bin/env bash
# ===========================================================================
# 接受发给 super-agent（<agent-account>）的仓库协作邀请
#   场景：你在自己的账号下创建仓库 → 邀请 <agent-account> 为协作者（Write）→
#         运行本脚本，让 agent 自动接受邀请，然后即可 switch-repo.sh 切过去。
#   用法: scripts/accept-invites.sh [容器名]（默认 dsh-superagent）
# ===========================================================================
set -euo pipefail
C="${1:-dsh-superagent}"

echo "== 待接受的邀请 =="
docker exec "$C" gh-agent api user/repository_invitations \
  --jq '.[] | "\(.id)\t\(.repository.full_name)\t\(.permissions)"' 2>&1 || true

IDS="$(docker exec "$C" gh-agent api user/repository_invitations --jq '.[].id' 2>/dev/null || true)"
if [ -z "${IDS:-}" ]; then
  echo "没有待接受的邀请。"
  exit 0
fi

for id in $IDS; do
  echo "接受邀请 $id ..."
  if docker exec "$C" gh-agent api -X PATCH "user/repository_invitations/$id" >/dev/null 2>&1; then
    echo "  ✔ 已接受"
  else
    echo "  ✘ 接受失败（检查邀请是否过期）"
  fi
done

echo "== 剩余待接受 =="
docker exec "$C" gh-agent api user/repository_invitations --jq 'length' 2>&1 | tail -1
