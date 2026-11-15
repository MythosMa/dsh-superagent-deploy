# ===========================================================================
# super-agent 一键部署（独立部署仓库，Windows PowerShell）
#
#   用法: powershell -ExecutionPolicy Bypass -File scripts/setup.ps1 [-WithMysql] [-WithGo] [-WithFlutter] [-Repo URL] [-Ref REF]
#     -WithMysql   同时启动 MySQL（默认不启动）
#     -WithGo      安装 Go 工具链（默认不装）
#     -WithFlutter 安装 Flutter SDK（默认不装）
#     -Repo/-Ref   源码仓库与 ref（默认上游 prototype @ main）
#   环境变量: DSA_DATA_DIR（默认 %USERPROFILE%\dsh-superagent-data）
# ===========================================================================
param(
  [switch]$WithMysql,
  [switch]$WithGo,
  [switch]$WithFlutter,
  [string]$Repo = '',
  [string]$Ref = ''
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot   # scripts → 仓库根
Set-Location $Root

$DataDir = if ($env:DSA_DATA_DIR) { $env:DSA_DATA_DIR } else { Join-Path $env:USERPROFILE 'dsh-superagent-data' }
# 统一用正斜杠，避免 Compose 解析 Windows 反斜杠的问题
$env:DSA_DATA_DIR = $DataDir -replace '\\', '/'

$env:SUPERAGENT_INSTALL_GO = if ($WithGo) { '1' } else { '0' }
$env:SUPERAGENT_INSTALL_FLUTTER = if ($WithFlutter) { '1' } else { '0' }
if ($Repo) { $env:SUPERAGENT_REPO = $Repo }
if ($Ref) { $env:SUPERAGENT_REF = $Ref }

Write-Host "== 1/5 检查 Docker =="
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "未找到 docker，请先安装 Docker Desktop" }
docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "未找到 docker compose 插件（请升级 Docker Desktop）" }
docker info | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker 未运行，请先启动 Docker Desktop" }

Write-Host "== 2/5 初始化数据目录: $DataDir =="
& (Join-Path $PSScriptRoot 'init-data.ps1') $DataDir

Write-Host "== 3/5 构建镜像（首次会拉取源码并下载依赖，约 10-30 分钟）=="
docker compose -f compose.yaml build
if ($LASTEXITCODE -ne 0) { throw "镜像构建失败" }

Write-Host "== 4/5 启动容器 =="
if ($WithMysql) {
  docker compose -f compose.yaml --profile mysql up -d
} else {
  docker compose -f compose.yaml up -d
}
if ($LASTEXITCODE -ne 0) { throw "容器启动失败" }

Write-Host "== 5/5 等待服务就绪 =="
$ok = $false
for ($i = 0; $i -lt 90; $i++) {
  Start-Sleep -Seconds 2
  try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:3082/orchestrator/api/state' `
         -Headers @{ 'x-orchestrator-request' = '1' } -UseBasicParsing -TimeoutSec 3
    if ($r.StatusCode -eq 200) { $ok = $true; break }
  } catch { }
}
if (-not $ok) { throw "等待超时：请检查 docker logs dsh-superagent" }

$token = ''
try {
  $m = docker logs dsh-superagent 2>&1 | Select-String -Pattern 'http://127.0.0.1:3082/\?token=[A-Za-z0-9_-]*' | Select-Object -Last 1
  if ($m) { $token = $m.Matches[0].Value }
} catch { }

Write-Host ""
Write-Host "================ 部署完成 ================"
Write-Host "面板:   http://127.0.0.1:3082/"
if ($token) { Write-Host "Token:  $token" }
if ($WithMysql) { Write-Host "MySQL:  127.0.0.1:13306  （账号密码见 $DataDir\mysql.env）" }
Write-Host ""
Write-Host "下一步（首次必做）："
Write-Host "  1) 浏览器打开面板，配置模型 provider 与 API key"
Write-Host "  2) docker exec -it dsh-superagent gh-agent auth login   # 登录 agent 的 GitHub 账号（device flow）"
Write-Host "  3) 面板 Superagent → Sources: 填仓库 owner/name 与 CLI /usr/local/bin/gh-agent"
Write-Host "     Policy: 允许名单填你的 GitHub 登录名；Executor: directory=/work + prepare 命令"
Write-Host "  4) 在仓库 Issue 里发新评论 @<agent账号> 派活"
Write-Host "=========================================="
