# ---------------------------------------------------------------------------
# super-agent 部署镜像（独立部署仓库）
# 构建时从 GitHub 拉取 super-agent 源码（可指定仓库与 ref），再编译 bundle 进镜像
# 原则：镜像 = 无密钥、可重建的环境；所有状态/密钥走 /data 挂载卷
#
# 构建参数：
#   SUPERAGENT_REPO   源码仓库（默认上游 prototype）
#   SUPERAGENT_REF    分支/tag/commit（默认 main；生产建议钉 commit）
#   GO_VERSION / GH_VERSION / FLUTTER_TAG  工具链版本
#   INSTALL_GO=1 / INSTALL_FLUTTER=1       启用对应工具链（默认不装）
# 需要其他开发环境：编辑 toolchains/extra.sh（构建时自动执行）
# ---------------------------------------------------------------------------

# ==================== 阶段 1：拉取源码并构建 bundle ====================
FROM node:24-bookworm-slim AS bundle-builder
ARG SUPERAGENT_REPO=https://github.com/deepseek-ai/dsh-superagent-prototype.git
ARG SUPERAGENT_REF=main

ARG DEBIAN_MIRROR=
RUN if [ -n "${DEBIAN_MIRROR}" ]; then \
      sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    fi
RUN apt-get update -o Acquire::Retries=5 \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# 完整克隆后 checkout 指定 ref（支持分支/tag/commit）
RUN git clone "${SUPERAGENT_REPO}" /src && git -C /src checkout "${SUPERAGENT_REF}"

RUN npm install -g pnpm@11.7.0
RUN pnpm install --frozen-lockfile && pnpm build

# ==================== 阶段 2：运行时 ====================
FROM node:24-bookworm-slim

# ---- 版本 ARG（构建时覆盖）----
ARG GO_VERSION=1.23.4
ARG GH_VERSION=2.62.0
ARG FLUTTER_TAG=stable        # 建议后期钉一个具体版本（如 3.27.1）保证可复现
# ---- 可选工具链开关（默认不安装；1=启用）----
ARG INSTALL_GO=0
ARG INSTALL_FLUTTER=0

ENV DEBIAN_FRONTEND=noninteractive

# ---- 基础工具 ----
ARG DEBIAN_MIRROR=
RUN if [ -n "${DEBIAN_MIRROR}" ]; then \
      sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    fi
RUN apt-get update -o Acquire::Retries=5 \
    && apt-get install -y --no-install-recommends \
    git git-lfs tmux python3 ca-certificates curl unzip xz-utils zip \
    gosu procps openssh-client libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# ---- Go（可选：INSTALL_GO=1 启用；按 CPU 架构下载官方 tarball）----
RUN set -e; if [ "${INSTALL_GO}" = "1" ]; then \
      arch="$(uname -m)"; \
      case "$arch" in aarch64) goarch=arm64 ;; x86_64) goarch=amd64 ;; *) echo "unsupported: $arch"; exit 1 ;; esac; \
      curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" -o /tmp/go.tgz; \
      rm -rf /usr/local/go; tar -C /usr/local -xzf /tmp/go.tgz; rm /tmp/go.tgz; \
    fi
ENV PATH="/usr/local/go/bin:${PATH}"

# ---- GitHub CLI（官方 release tarball；版本不存在会让构建失败，改 ARG 即可）----
RUN arch=$(uname -m) && case "$arch" in \
      aarch64) gharch=arm64 ;; x86_64) gharch=amd64 ;; *) echo "unsupported: $arch"; exit 1;; \
    esac \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gharch}.tar.gz" -o /tmp/gh.tgz \
    && tar -C /tmp -xzf /tmp/gh.tgz \
    && cp "/tmp/gh_${GH_VERSION}_linux_${gharch}/bin/gh" /usr/local/bin/gh \
    && cp -r "/tmp/gh_${GH_VERSION}_linux_${gharch}/share/man" /usr/local/share/ \
    && rm -rf /tmp/gh.tgz /tmp/gh_${GH_VERSION}_linux_${gharch}

# ---- Flutter（可选：INSTALL_FLUTTER=1 启用）
# 注意：ENV PATH 必须在 RUN 之前，否则本层运行时 flutter 不在 PATH 上
ENV PATH="/opt/flutter/bin:${PATH}"
RUN set -e; if [ "${INSTALL_FLUTTER}" = "1" ]; then \
      git clone --depth 1 -b "${FLUTTER_TAG}" https://github.com/flutter/flutter.git /opt/flutter; \
      flutter config --no-analytics; \
      flutter --version; \
    fi

# ---- pnpm + dsh（钉版本；engines.dsh 要求 ^0.2.1-alpha.2，文档钉 0.2.1-rc.3）----
# --allow-scripts 放行 native 依赖的安装脚本（node-pty/koffi/subprocess 等，dsh 必需）
RUN npm install -g --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
    pnpm@11.7.0 @deepseek-ai/dsh@0.2.1-rc.3

# ---- 复制构建好的 bundle ----
COPY --from=bundle-builder /src /opt/dsh-superagent

# ---- socat：宿主端口转发用（放晚层，避免使前方大依赖层缓存失效）----
# apt 源偶发 502，重试 3 次再放弃
RUN for i in 1 2 3; do \
      apt-get update -o Acquire::Retries=5 && break || sleep 5; \
    done \
    && apt-get install -y --no-install-recommends socat \
    && rm -rf /var/lib/apt/lists/*

# ---- 专用非 root 用户（对应文档"专用 OS 账号"建议）----
# 注意：node:24 官方镜像已占用 uid 1000（node 用户），dsh 用 1001 避免冲突
RUN useradd --create-home --uid 1001 dsh

# ---- gh-agent 包装：只认 /data/gh-agent 里的凭据（镜像内无任何登录态）----
RUN printf '#!/bin/sh\nGH_CONFIG_DIR=/data/gh-agent exec gh "$@"\n' > /usr/local/bin/gh-agent \
    && chmod +x /usr/local/bin/gh-agent

# ---- 可选：自定义工具链钩子（toolchains/extra.sh，默认空）----
COPY toolchains/ /opt/toolchains/
RUN set -e; if [ -f /opt/toolchains/extra.sh ]; then chmod +x /opt/toolchains/extra.sh; bash /opt/toolchains/extra.sh; fi

# ---- 入口 ----
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /home/dsh
ENV DSH_HOME=/data/dsh \
    GH_CONFIG_DIR=/data/gh-agent \
    PATH="/opt/flutter/bin:/usr/local/go/bin:${PATH}"

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["dsh", "--profile", "superagent", "--no-open"]
