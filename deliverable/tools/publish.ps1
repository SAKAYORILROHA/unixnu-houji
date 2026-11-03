# 通过 GitHub REST API 发布 houji 设备仓库并触发 macOS 内核构建。
# 用法：
#   $env:GH_TOKEN = "<personal access token>"
#   pwsh -File D:\13u\port\tools\publish.ps1                 # 建仓库 + 推送 + 触发
#   pwsh -File D:\13u\port\tools\publish.ps1 -Push only      # 只推送
param(
  [string]$Owner,                 # 默认取 token 的登录名
  [string]$Repo = 'unixnu-houji',
  [string]$Source = 'D:\13u\port\device\upload',
  [switch]$SkipRepoCreate,
  [switch]$SkipDispatch,
  [string]$Workflow = 'houji-kernel.yml',
  [string]$Ref = 'main'
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

function Invoke-GH {
  param([string]$Method, [string]$Path, $Body, [string]$ContentType = 'application/json')
  $uri = if ($Path -like 'http*') { $Path } else { "$api$Path" }
  $args = @{ Method = $Method; Uri = $uri; Headers = $headers }
  if ($null -ne $Body) {
    $args.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 -Compress }
    $args.ContentType = $ContentType
  }
  return Invoke-RestMethod @args
}

# 1) 身份
if (-not $Owner) {
  $me = Invoke-GH GET '/user'
  $Owner = $me.login
  Write-Host "owner: $Owner"
}

# 2) 建仓库（默认 public：Actions macOS runner 对公共仓库免费）
if (-not $SkipRepoCreate) {
  try {
    Invoke-GH POST '/user/repos' @{
      name        = $Repo
      description = 'Xiaomi 14 (houji / SM8650) UniXNU port: device repository and macOS kernel workflow'
      private     = $false
      auto_init   = $false
    } | Out-Null
    Write-Host "created $Owner/$Repo"
  } catch {
    Write-Host "repo create skipped: $($_.Exception.Message)"
  }
}

# 3) 上传所有文件为一个 commit（git data API）
$root = (Resolve-Path $Source).Path
$files = Get-ChildItem -Path $root -Recurse -File |
  Where-Object { $_.FullName -notmatch '\\\.git\\' }
Write-Host "files: $($files.Count)"

$tree = @()
foreach ($f in $files) {
  $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $b64 = [Convert]::ToBase64String($bytes)
  $blob = Invoke-GH POST "/repos/$Owner/$Repo/git/blobs" @{ content = $b64; encoding = 'base64' }
  $tree += @{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha }
  Write-Host ("  {0}  {1} bytes -> {2}" -f $rel, $bytes.Length, $blob.sha.Substring(0, 8))
}

$newTree = Invoke-GH POST "/repos/$Owner/$Repo/git/trees" @{ tree = $tree }
$commit = Invoke-GH POST "/repos/$Owner/$Repo/git/commits" @{
  message = 'houji device repository: defconfig, patches, scripts, inputs and macOS kernel workflow'
  tree    = $newTree.sha
  parents = @()
}
try {
  Invoke-GH POST "/repos/$Owner/$Repo/git/refs" @{ ref = "refs/heads/$Ref"; sha = $commit.sha } | Out-Null
  Write-Host "pushed $Ref @ $($commit.sha.Substring(0, 8))"
} catch {
  Invoke-GH PATCH "/repos/$Owner/$Repo/git/refs/heads/$Ref" @{ sha = $commit.sha; force = $true } | Out-Null
  Write-Host "updated $Ref @ $($commit.sha.Substring(0, 8))"
}

# 4) 触发 workflow
if (-not $SkipDispatch) {
  Start-Sleep -Seconds 3
  Invoke-GH POST "/repos/$Owner/$Repo/actions/workflows/$Workflow/dispatches" @{ ref = $Ref } | Out-Null
  Write-Host "dispatched $Workflow on $Ref"
  Write-Host "跟踪: https://github.com/$Owner/$Repo/actions"
}
