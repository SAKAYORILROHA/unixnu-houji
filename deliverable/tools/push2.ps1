# Push the staged device repository to GitHub through the REST API.
# An empty repository has no git objects, so seed it with one file through the Contents API first.
param(
  [string]$Repo = 'unixnu-houji',
  [string]$Owner = 'SAKAYORILROHA',
  [string]$Source = 'D:\13u\port\device\upload',
  [string]$TokenFile = 'D:\13u\port\tools\.gh_token'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$token = (Get-Content $TokenFile -Raw).Trim()
$h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-houji-port' }
$api = 'https://api.github.com'
$base = "$api/repos/$Owner/$Repo"

function GH($method, $uri, $body) {
  $p = @{ Method = $method; Uri = $uri; Headers = $h }
  if ($body) { $p.ContentType = 'application/json'; $p.Body = $body }
  return Invoke-RestMethod @p
}

# 1) seed the empty repository (Contents API creates the first commit and branch)
$parent = $null
try {
  $ref = GH 'GET' "$base/git/ref/heads/main" $null
  $parent = $ref.object.sha
  Write-Host "existing main @ $($parent.Substring(0,8))"
} catch {
  Write-Host 'repository is empty: seeding with README.md'
  $seed = "# houji device repository`n`nDevice definition, patches, scripts and the macOS kernel workflow for the Xiaomi 14 (houji / SM8650) UniXNU port.`n"
  $body = @{ message = 'seed repository'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($seed)); branch = 'main' } | ConvertTo-Json -Compress
  $r = GH 'PUT' "$base/contents/README.md" $body
  $parent = $r.commit.sha
  Write-Host "seeded @ $($parent.Substring(0,8))"
}

# 2) upload every file as one tree/commit
$root = (Resolve-Path $Source).Path
$files = Get-ChildItem -Path $root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' }
Write-Host "files: $($files.Count)"
$tree = New-Object System.Collections.ArrayList
$i = 0
foreach ($f in $files) {
  $i++
  $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
  $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
  $blob = GH 'POST' "$base/git/blobs" (@{ content = $b64; encoding = 'base64' } | ConvertTo-Json -Compress)
  [void]$tree.Add(@{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha })
  if ($i % 25 -eq 0) { Write-Host "  uploaded $i / $($files.Count)" }
}
Write-Host "blobs done: $($tree.Count)"

$newTree = GH 'POST' "$base/git/trees" (@{ tree = $tree } | ConvertTo-Json -Depth 8 -Compress)
$commit = GH 'POST' "$base/git/commits" (@{
    message = 'houji device repository: defconfig, patches, scripts, inputs, macOS kernel workflow'
    tree = $newTree.sha; parents = @($parent)
  } | ConvertTo-Json -Depth 6 -Compress)
Write-Host "commit: $($commit.sha.Substring(0,8))"
GH 'PATCH' "$base/git/refs/heads/main" (@{ sha = $commit.sha; force = $true } | ConvertTo-Json -Compress) | Out-Null
Write-Host "main -> $($commit.sha.Substring(0,8))"
Write-Host "https://github.com/$Owner/$Repo"
