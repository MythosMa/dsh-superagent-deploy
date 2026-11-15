# ===========================================================================
# 宿主机数据目录初始化（Windows PowerShell）
#   用法: powershell -ExecutionPolicy Bypass -File scripts/init-data.ps1 [数据目录]
#   默认数据目录: $env:USERPROFILE\dsh-superagent-data（可用 DSA_DATA_DIR 覆盖）
# ===========================================================================
param(
  [string]$DataDir = $(if ($env:DSA_DATA_DIR) { $env:DSA_DATA_DIR } else { Join-Path $env:USERPROFILE 'dsh-superagent-data' })
)

$ErrorActionPreference = 'Stop'

# 生成随机密码
function New-Password {
  -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
}

# 子目录
foreach ($sub in @('profile', 'gh-agent', 'state', 'mysql')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $DataDir $sub) | Out-Null
}

# mysql.env
$mysqlEnv = Join-Path $DataDir 'mysql.env'
if (-not (Test-Path $mysqlEnv)) {
  $root = New-Password
  $worker = New-Password
  @"
# 由 init-data.ps1 生成
MYSQL_ROOT_PASSWORD=$root
MYSQL_DATABASE=super_agent_test
MYSQL_USER=sa_worker
MYSQL_PASSWORD=$worker
"@ | Set-Content -Encoding ASCII $mysqlEnv
  Write-Host "[init-data] mysql.env 已生成 → $mysqlEnv"
} else {
  Write-Host "[init-data] mysql.env 已存在，跳过"
}

# superagent.env
$saEnv = Join-Path $DataDir 'superagent.env'
if (-not (Test-Path $saEnv)) {
  New-Item -ItemType File -Force -Path $saEnv | Out-Null
  Write-Host "[init-data] superagent.env 已生成（空模板）"
} else {
  Write-Host "[init-data] superagent.env 已存在，跳过"
}

Write-Host ""
Write-Host "==== 数据目录就绪: $DataDir ===="
Write-Host "面板:   http://127.0.0.1:3082/"
Write-Host "MySQL:  127.0.0.1:13306  （账号见 $mysqlEnv）"
