# Create the device repository and push it as one commit through the GitHub REST API.
# (git push is unusable here: github.com is not reachable from this machine.)
param(
  [string]$Repo = 'unixnu-houji',
  [string]$Source = 'D:\13u\port\device\upload',
  [string]$TokenFile = 'D:\13u\port\tools\.gh_token'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$token = (Get-Content $TokenFile -Raw).Trim()
$h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-houji-port' }
$api = 'https://api.github.com'

$me = Invoke-RestMethod -Uri "$api/user" -Headers $h
$owner = $me.login
Write-Host "owner: $owner"

$created = $false
try {
  $body = @{ name = $Repo; description = 'Xiaomi 14 houji SM8650 UniXNU port: device repo + macOS kernel workflow'; private = $false; auto_init = $false } | ConvertTo-Json
  Invoke-RestMethod -Method POST -Uri "$api/user/repos" -Headers $h -ContentType 'application/json' -Body $body | Out-Null
  $created = $true
  Write-Host "created $owner/$Repo"
} catch {
  $code = '?'
  if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
  Write-Host "repo create failed ($code): $($_.Exception.Message)"
}

try {
  Invoke-RestMethod -Uri "$api/repos/$owner/$Repo" -Headers $h | Out-Null
  Write-Host "repo reachable: $owner/$Repo"
} catch {
  Write-Host "repo NOT reachable - create an empty repository named $Repo on the web and rerun"
  exit 2
}

$root = (Resolve-Path $Source).Path
$files = Get-ChildItem -Path $root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' }
Write-Host "files: $($files.Count)"
$tree = New-Object System.Collections.ArrayList
$i = 0
foreach ($f in $files) {
  $i++
  $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
  $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
  $body = @{ content = $b64; encoding = 'base64' } | ConvertTo-Json -Compress
  $blob = Invoke-RestMethod -Method POST -Uri "$api/repos/$owner/$Repo/git/blobs" -Headers $h -ContentType 'application/json' -Body $body
  [void]$tree.Add(@{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha })
  if ($i % 25 -eq 0) { Write-Host "  uploaded $i / $($files.Count)" }
}
Write-Host "blobs done: $($tree.Count)"

$treeBody = @{ tree = $tree } | ConvertTo-Json -Depth 8 -Compress
$newTree = Invoke-RestMethod -Method POST -Uri "$api/repos/$owner/$Repo/git/trees" -Headers $h -ContentType 'application/json' -Body $treeBody
$commitBody = @{ message = 'houji device repository: defconfig, patches, scripts, inputs, macOS kernel workflow'; tree = $newTree.sha; parents = @() } | ConvertTo-Json -Depth 6 -Compress
$commit = Invoke-RestMethod -Method POST -Uri "$api/repos/$owner/$Repo/git/commits" -Headers $h -ContentType 'application/json' -Body $commitBody
Write-Host "commit: $($commit.sha.Substring(0,8))"

try {
  $refBody = @{ ref = 'refs/heads/main'; sha = $commit.sha } | ConvertTo-Json -Compress
  Invoke-RestMethod -Method POST -Uri "$api/repos/$owner/$Repo/git/refs" -Headers $h -ContentType 'application/json' -Body $refBody | Out-Null
  Write-Host 'branch main created'
} catch {
  $refBody = @{ sha = $commit.sha; force = $true } | ConvertTo-Json -Compress
  Invoke-RestMethod -Method PATCH -Uri "$api/repos/$owner/$Repo/git/refs/heads/main" -Headers $h -ContentType 'application/json' -Body $refBody | Out-Null
  Write-Host 'branch main updated'
}
Write-Host "repo url: https://github.com/$owner/$Repo"
