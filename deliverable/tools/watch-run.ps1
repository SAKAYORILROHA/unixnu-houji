param(
  [string]$Owner = 'SAKAYORILROHA',
  [string]$Repo = 'unixnu-houji',
  [string]$TokenFile = 'D:\13u\port\tools\.gh_token',
  [long]$RunId = 0,
  [int]$Minutes = 45
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$token = (Get-Content $TokenFile -Raw).Trim()
$h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-houji-port' }
$api = 'https://api.github.com'
$base = "$api/repos/$Owner/$Repo"

if ($RunId -eq 0) {
  $runs = Invoke-RestMethod -Uri "$base/actions/runs?per_page=1" -Headers $h
  $RunId = $runs.workflow_runs[0].id
}
Write-Host "watching run $RunId"
$deadline = (Get-Date).AddMinutes($Minutes)
$last = ''
while ((Get-Date) -lt $deadline) {
  $run = Invoke-RestMethod -Uri "$base/actions/runs/$RunId" -Headers $h
  $state = "$($run.status)/$($run.conclusion)"
  if ($state -ne $last) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $state)
    $last = $state
  }
  if ($run.status -eq 'completed') {
    $jobs = Invoke-RestMethod -Uri "$base/actions/runs/$RunId/jobs" -Headers $h
    foreach ($j in $jobs.jobs) {
      Write-Host ("job {0}: {1}/{2}" -f $j.name, $j.status, $j.conclusion)
      foreach ($s in $j.steps) { Write-Host ("   - {0}: {1} {2}" -f $s.name, $s.status, $s.conclusion) }
    }
    break
  }
  Start-Sleep -Seconds 45
}
