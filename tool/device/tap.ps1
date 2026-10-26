# 用 uiautomator dump 精确定位控件并点击（M2 真机补测用）
# 用法：
#   powershell -File tool/device/tap.ps1 -Pattern '打开样本专辑'
#   powershell -File tool/device/tap.ps1 -Pattern 'Tab 2 of 3'
#   powershell -File tool/device/tap.ps1 -Pattern '播放' -Index 0
param(
    [Parameter(Mandatory = $true)][string]$Pattern,
    [int]$Index = 0,
    [string]$Adb = "E:\android-sdk\platform-tools\adb.exe",
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP 'kele-ui.xml'

& $Adb shell uiautomator dump /sdcard/ui.xml | Out-Null
& $Adb pull /sdcard/ui.xml $tmp | Out-Null

[xml]$xml = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
$nodes = $xml.SelectNodes("//node[@content-desc!='']")
$hit = @($nodes | Where-Object { $_.'content-desc' -match $Pattern })

if ($List) {
    $hit | ForEach-Object { "{0}  bounds={1}" -f $_.'content-desc', $_.bounds }
    exit 0
}

if ($hit.Count -eq 0) {
    Write-Error "未找到匹配 [$Pattern] 的控件。可用列表："
    $nodes | ForEach-Object { "  {0}  {1}" -f $_.'content-desc', $_.bounds }
    exit 1
}

if ($Index -ge $hit.Count) { Write-Error "Index $Index 越界（命中 $($hit.Count) 个）"; exit 1 }
$node = $hit[$Index]
if ($node.clickable -ne 'true') { Write-Warning "命中节点不可点击：$($node.'content-desc')" }

$m = [regex]::Match($node.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
$x = ([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2
$y = ([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2

Write-Host ("tap ({0},{1})  <= {2}" -f $x, $y, ($node.'content-desc' -replace "`n", ' | '))
& $Adb shell input tap $x $y
