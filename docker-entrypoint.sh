#!/bin/sh
# ===========================================================================
# dsh-superagent 容器入口
# 职责（root 阶段）：
#   1. 确保 /data 三个状态目录与 /work 存在并归属 dsh 用户
#   2. 首次启动：从 web 模板创建 superagent profile，写入机器配置
#      （webserver 127.0.0.1:3082 + stateDir /data/state），挂载 bundle
#   3. 以非 root 用户 dsh 启动 dsh（CMD 传入）
# 注意：本脚本内不携带任何密钥；配置与凭据都在 /data 挂载卷中。
# ===========================================================================
set -eu

DSH_HOME=/data/dsh
GH_CFG=/data/gh-agent
STATE=/data/state
WORK=/work
BUNDLE=/opt/dsh-superagent
PROFILE_DIR="$DSH_HOME/profiles/superagent"

# ---- 1. 目录与属主（首次挂载为空目录时必须）----
mkdir -p "$DSH_HOME" "$GH_CFG" "$STATE" "$WORK"
# proper-lockfile 会在 stateDir 的父目录创建 <name>.lock（如 /data/state.lock），
# 因此 /data 根也必须归 dsh 所有，否则 orchestrator 启动报 EACCES
chown dsh:dsh /data
chown -R dsh:dsh "$DSH_HOME" "$GH_CFG" "$STATE" "$WORK"

# ---- 2. 首次启动初始化 ----
if [ ! -f "$PROFILE_DIR/cordis.patch.yml" ]; then
  echo "[entrypoint] first boot: creating superagent profile from web template"
  gosu dsh env DSH_HOME="$DSH_HOME" GH_CONFIG_DIR="$GH_CFG" \
    dsh superagent --from-default-profile web --dump-config >/dev/null

  # 机器配置：改例子里的 stateDir 占位符为 /data/state（webserver 保持 127.0.0.1:3082）
  # 注意：orchestrator 强制 webserver 绑 127.0.0.1（src/app/http.ts），且 DSH 拒绝 0.0.0.0，
  #       宿主侧访问经下方的 socat 转发进入（见步骤 2b）
  sed -e 's|<absolute path[^>]*>|/data/state|' \
      "$BUNDLE/examples/profile.cordis.patch.yml" \
      > "$PROFILE_DIR/cordis.patch.yml"

  echo "[entrypoint] adding bundle to profile"
  gosu dsh env DSH_HOME="$DSH_HOME" GH_CONFIG_DIR="$GH_CFG" \
    dsh plugin --profile superagent add "link:$BUNDLE"
fi

# ---- 2b. 端口转发：宿主 → 容器网桥 3182 → 127.0.0.1:3082 ----
# dsh web/orchestrator 只监听容器内 127.0.0.1:3082（强制回环 + Host 校验 127.0.0.1:3082）；
# socat 监听容器网桥侧 3182，把连接转发回回环 3082，这样 compose 的
# 宿主端口 `127.0.0.1:3082 -> 3182` 才能把浏览器/API 请求送进 dsh。
# socat 以 dsh 用户后台运行，随主进程共存；容器停止时由 PID1(init) 收尾。
gosu dsh sh -c 'socat TCP-LISTEN:3182,fork,reuseaddr TCP:127.0.0.1:3082' &
sleep 1

# ---- 3. 交棒给非 root 用户运行 dsh ----
exec gosu dsh env DSH_HOME="$DSH_HOME" GH_CONFIG_DIR="$GH_CFG" "$@"