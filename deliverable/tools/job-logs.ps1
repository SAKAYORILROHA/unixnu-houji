param(
  [string]$Owner = 'SAKAYORILROHA',
  [string]$Repo = 'unixnu-houji',
  [long]$RunId = 41258138154,
  [string]$Out = 'D:\13u\port\ci\job-logs.zip',
  [string]$TokenFile = 'D:\13u\port\tools\.gh_token'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$token = (Get-Content $TokenFile -Raw).Trim()
$h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-houji-port' }
$base = "https://api.github.com/repos/$Owner/$Repo"

$jobs = Invoke-RestMethod -Uri "$base/actions/runs/$RunId/jobs" -Headers $h
foreach ($j in $jobs.jobs) { Write-Host "job $($j.id): $($j.name) $($j.status)/$($j.conclusion)" }

$job = $jobs.jobs | Where-Object { $_.conclusion -eq 'failure' } | Select-Object -First 1
if (-not $job) { Write-Host 'no failed job'; exit 0 }
Write-Host "fetching logs for job $($job.id)"

$resp = Invoke-WebRequest -Uri "$base/actions/jobs/$($job.id)/logs" -Headers $h -UseBasicParsing
if ($resp.RawContentStream) {
  $fs = [System.IO.File]::Create($Out)
  $resp.RawContentStream.Position = 0
  $resp.RawContentStream.CopyTo($fs)
  $fs.Close()
} else {
  [System.IO.File]::WriteAllBytes($Out, $resp.Content)
}
Write-Host ("saved {0} ({1:N1} MB)" -f $Out, ((Get-Item $Out).Length / 1MB))
