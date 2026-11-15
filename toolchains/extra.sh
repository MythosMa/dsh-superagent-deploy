#!/usr/bin/env bash
# ===========================================================================
# 自定义工具链钩子（可选）
# 镜像构建时以 root 身份执行一次；默认什么都不做。
# 需要额外开发环境时，在这里写安装命令，例如：
#   apt-get update && apt-get install -y --no-install-recommends rustc cargo
#   curl -fsSL https://example.com/tool.tar.gz | tar -C /usr/local -xz
#   python3 -m pip install --break-system-packages some-package
# 注意：只写安装步骤，不要在这里放任何密钥/凭据。
# ===========================================================================
set -e
# 你的安装命令写在这里（默认无操作）
true
