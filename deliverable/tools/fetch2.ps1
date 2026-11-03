param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [string]$Repo = 'unixnu-houji',
  [string]$OutDir = 'D:\13u\port\ci',
  [long]$RunId = 0,
  [string]$TokenFile = 'D:\13u\port\tools\.gh_token'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$token = (Get-Content $TokenFile -Raw).Trim()
$h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-houji-port' }
$api = 'https://api.github.com'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$base = "$api/repos/$Owner/$Repo"

if ($RunId -eq 0) {
  $runs = Invoke-RestMethod -Uri "$base/actions/runs?per_page=5" -Headers $h
  $RunId = $runs.workflow_runs[0].id
}
Write-Host "run: $RunId"

$arts = Invoke-RestMethod -Uri "$base/actions/runs/$RunId/artifacts" -Headers $h
foreach ($a in $arts.artifacts) {
  Write-Host ("artifact {0} ({1:N1} MB expired={2})" -f $a.name, ($a.size_in_bytes / 1MB), $a.expired)
  if ($a.expired) { continue }
  $zip = Join-Path $OutDir ("$($a.name).zip")
  Invoke-WebRequest -Uri "$base/actions/artifacts/$($a.id)/zip" -Headers $h -OutFile $zip -UseBasicParsing
  Write-Host "saved $zip"
  $dest = Join-Path $OutDir $a.name
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  Expand-Archive -Path $zip -DestinationPath $dest -Force
}

Write-Host ''
Write-Host 'interesting files:'
Get-ChildItem -Path $OutDir -Recurse -File |
  Where-Object { $_.Name -match 'kernel\.macho|unstripped|\.log$' } |
  Select-Object -First 25 FullName, Length | Format-Table -AutoSize
