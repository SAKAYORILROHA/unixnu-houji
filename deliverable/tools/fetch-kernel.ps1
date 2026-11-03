# 等 CI 出内核后，把产物拉回本机并合成可启动镜像。
# 用法（需要 GH_TOKEN 才能下载私有仓库产物；public 仓库的 artifact 也需要登录）：
#   $env:GH_TOKEN = "<token>"
#   pwsh -File D:\13u\port\tools\fetch-kernel.ps1 -Owner <you> -Repo unixnu-houji
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [string]$Repo = 'unixnu-houji',
  [string]$OutDir = 'D:\13u\port\ci',
  [int]$RunId = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$token = $env:GH_TOKEN
if (-not $token) { throw 'GH_TOKEN 未设置' }
$headers = @{
  Authorization          = "Bearer $token"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'dsh-houji-port'
}
$api = 'https://api.github.com'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if ($RunId -eq 0) {
  $runs = Invoke-RestMethod -Uri "$api/repos/$Owner/$Repo/actions/runs?per_page=5" -Headers $headers
  $run = $runs.workflow_runs | Select-Object -First 1
  if (-not $run) { throw '找不到 workflow run' }
  $RunId = $run.id
  Write-Host ("run {0}: {1} ({2})" -f $run.id, $run.display_title, $run.status)
}

$arts = Invoke-RestMethod -Uri "$api/repos/$Owner/$Repo/actions/runs/$RunId/artifacts" -Headers $headers
foreach ($a in $arts.artifacts) {
  Write-Host ("artifact {0} ({1:N1} MB, expired={2})" -f $a.name, ($a.size_in_bytes / 1MB), $a.expired)
  if ($a.expired) { continue }
  $zip = Join-Path $OutDir "$($a.name).zip"
  Invoke-WebRequest -Uri "$api/repos/$Owner/$Repo/actions/artifacts/$($a.id)/zip" -Headers $headers -OutFile $zip -UseBasicParsing
  Write-Host "downloaded -> $zip"
  Expand-Archive -Path $zip -DestinationPath (Join-Path $OutDir $a.name) -Force
}

Write-Host "`n产物目录：$OutDir"
Get-ChildItem -Path $OutDir -Recurse -File |
  Where-Object { $_.Name -match 'kernel\.macho|unstripped|\.log$' } |
  Select-Object -First 20 FullName, Length | Format-Table -AutoSize
