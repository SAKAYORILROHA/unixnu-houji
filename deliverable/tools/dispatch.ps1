param(
  [string]$Owner = 'SAKAYORILROHA',
  [string]$Repo = 'unixnu-houji',
  [string]$TokenFile = 'D:\13u\port\tools\.gh_token'
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$token = (Get-Content $TokenFile -Raw).Trim()
$h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-houji-port' }
$api = 'https://api.github.com'
$base = "$api/repos/$Owner/$Repo"

Start-Sleep -Seconds 5
$wfs = Invoke-RestMethod -Uri "$base/actions/workflows" -Headers $h
foreach ($w in $wfs.workflows) { Write-Host "workflow: $($w.name) -> $($w.path) ($($w.state))" }

$body = @{ ref = 'main'; inputs = @{ xcode = '26.6'; jobs = '4' } } | ConvertTo-Json -Depth 4 -Compress
try {
  Invoke-RestMethod -Method POST -Uri "$base/actions/workflows/houji-kernel.yml/dispatches" -Headers $h -ContentType 'application/json' -Body $body | Out-Null
  Write-Host 'dispatched houji-kernel.yml'
} catch {
  $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { '?' }
  Write-Host "dispatch failed ($code): $($_.Exception.Message)"
}

Start-Sleep -Seconds 10
$runs = Invoke-RestMethod -Uri "$base/actions/runs?per_page=3" -Headers $h
foreach ($r in $runs.workflow_runs) {
  Write-Host ("run {0}  {1}  {2}  {3}" -f $r.id, $r.name, $r.status, $r.html_url)
}
