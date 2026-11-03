# rebuild-and-boot.ps1 - rebuild the houji UniXNU image and optionally fastboot-boot it.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File rebuild-and-boot.ps1 -Mode kernel   # kernel + payload + firmware + image
#   powershell -ExecutionPolicy Bypass -File rebuild-and-boot.ps1 -Mode image    # payload + firmware + image (kernel unchanged)
#   powershell -ExecutionPolicy Bypass -File rebuild-and-boot.ps1 -Mode boot     # just push the existing image
#
# Options:
#   -Stage <n>     add boot-arg unixnu-hold=<n>   (omit for a normal boot image)
#   -NoBoot        build only, do not touch the device

param(
  [ValidateSet('kernel','image','boot')][string]$Mode = 'image',
  [int]$Stage = -1,
  [switch]$NoBoot
)

$ErrorActionPreference = 'Stop'
$Artifacts = 'D:\13u\port\artifacts'
$Adb = 'C:\platform-tools-latest-windows\platform-tools\adb.exe'
$Fb  = 'C:\platform-tools-latest-windows\platform-tools\fastboot.exe'
$Wsl = 'wsl.exe'

function Invoke-Wsl([string]$script) {
  Write-Host "== wsl: $script" -ForegroundColor Cyan
  & $Wsl -d Ubuntu -- bash $script
  if ($LASTEXITCODE -ne 0) { throw "wsl script failed ($LASTEXITCODE): $script" }
}

function Wait-Fastboot([int]$seconds = 90) {
  for ($i = 0; $i -lt $seconds; $i += 3) {
    if ((& $Fb devices 2>&1 | Select-String 'd2085791')) { return $true }
    Start-Sleep -Seconds 3
  }
  return $false
}

switch ($Mode) {
  'kernel' { Invoke-Wsl '/mnt/d/13u/tmp/hold-park.sh' }
  'image'  { }
  'boot'   { }
}

if ($Mode -ne 'boot') {
  $stageArg = if ($Stage -ge 0) { "$Stage" } else { 'none' }
  Invoke-Wsl "/mnt/d/13u/tmp/hold-image.sh $stageArg"
  $img = Join-Path $Artifacts "boot-houji-hold-$stageArg.img"
  Write-Host "built: $img" -ForegroundColor Green
} else {
  $stageArg = if ($Stage -ge 0) { "$Stage" } else { 'none' }
  $img = Join-Path $Artifacts "boot-houji-hold-$stageArg.img"
}

if ($NoBoot) { Write-Host 'skip device step'; exit 0 }
if (-not (Test-Path $img)) { throw "missing image: $img" }

# move the phone to fastboot if needed
if (-not (& $Fb devices 2>&1 | Select-String 'd2085791')) {
  if (& $Adb devices 2>&1 | Select-String 'd2085791\s+device') {
    Write-Host 'rebooting to bootloader...' -ForegroundColor Yellow
    & $Adb reboot bootloader 2>&1 | Out-Null
  }
  if (-not (Wait-Fastboot 90)) {
    Write-Host 'no fastboot device: power-cycle the phone (hold power 10s, then vol-down+power)' -ForegroundColor Red
    exit 2
  }
}

Write-Host "booting $img" -ForegroundColor Cyan
& $Fb boot $img 2>&1 | Select-Object -Last 1
