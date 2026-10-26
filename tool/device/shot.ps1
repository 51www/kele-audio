# 真机截图（PowerShell `>` 会破坏二进制，必须走 cmd 重定向）
# 用法：powershell -File tool/device/shot.ps1 -Name m2d-04-background
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Adb = "E:\android-sdk\platform-tools\adb.exe",
    [string]$Dir = "docs\shortscreen"
)

$ErrorActionPreference = 'Stop'
$out = Join-Path $Dir "$Name.png"
cmd /c "`"$Adb`" exec-out screencap -p > `"$out`""
$bytes = [IO.File]::ReadAllBytes($out)
$png = ($bytes[0..7] | ForEach-Object { $_.ToString('X2') }) -join ' '
if ($png -ne '89 50 4E 47 0D 0A 1A 0A') { Write-Error "截图不是有效 PNG：$out"; exit 1 }
Write-Host ("{0}  {1} bytes" -f $out, $bytes.Length)
