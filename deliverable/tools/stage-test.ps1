# 自动二分：对给定 stage 启动一次，用“adb 是否回来”判定 panic(回来) / hold(不回来)
param(
  [Parameter(Mandatory = $true)][int]$Stage,
  [int]$WaitSec = 110
)
$adb = 'C:\platform-tools-latest-windows\platform-tools\adb.exe'
$fb  = 'C:\platform-tools-latest-windows\platform-tools\fastboot.exe'
$img = "D:\13u\port\artifacts\boot-houji-hold-$Stage.img"

if (-not (Test-Path $img)) { "missing image: $img"; exit 2 }

# 让手机进 fastboot
if (-not (& $fb devices 2>&1 | Select-String 'd2085791')) {
  if (& $adb devices 2>&1 | Select-String 'd2085791\s+device') {
    & $adb reboot bootloader 2>&1 | Out-Null
    Start-Sleep -Seconds 14
  }
}
if (-not (& $fb devices 2>&1 | Select-String 'd2085791')) { "no fastboot device"; exit 3 }

& $fb boot $img 2>&1 | Select-Object -Last 1 | Out-Null
$t0 = Get-Date
for ($i = 0; $i -lt [int]($WaitSec / 2); $i++) {
  Start-Sleep -Seconds 2
  if (& $adb devices 2>&1 | Select-String 'd2085791\s+device') {
    "stage $Stage : PANIC (adb back after $([int]((Get-Date) - $t0).TotalSeconds)s)"
    exit 0
  }
}
"stage $Stage : HOLD reached (no adb in $WaitSec s)"
exit 0
