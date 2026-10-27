# 从 docs/images/icon.png 生成各类尺寸切图（全出血裁边 + 自适应图标前景/背景 + 应用内用图）
# 仅本机开发用，产物写入 docs/images 与 android res mipmap
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Bitmap]::new('E:\www\kele-audio\docs\images\icon.png')
Write-Output ("src: {0}x{1}" -f $src.Width, $src.Height)

# 1) 检测非透明内容的包围盒（icon 四角为透明）
$minX = $src.Width; $minY = $src.Height; $maxX = 0; $maxY = 0
for ($y = 0; $y -lt $src.Height; $y += 2) {
  for ($x = 0; $x -lt $src.Width; $x += 2) {
    if ($src.GetPixel($x, $y).A -gt 8) {
      if ($x -lt $minX) { $minX = $x }
      if ($x -gt $maxX) { $maxX = $x }
      if ($y -lt $minY) { $minY = $y }
      if ($y -gt $maxY) { $maxY = $y }
    }
  }
}
Write-Output ("bbox: ({0},{1})-({2},{3})" -f $minX, $minY, $maxX, $maxY)

$cropW = $maxX - $minX + 1
$cropH = $maxY - $minY + 1

function Resize ([System.Drawing.Bitmap]$bmp, [int]$size) {
  $dst = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($dst)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.DrawImage($bmp, 0, 0, $size, $size)
  $g.Dispose()
  return $dst
}

function Save ([System.Drawing.Bitmap]$bmp, [string]$path) {
  $dir = Split-Path $path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Output "saved: $path"
}

# 2) 全出血版：裁掉透明边，圆角方块顶满画布
$full = $src.Clone([System.Drawing.Rectangle]::new($minX, $minY, $cropW, $cropH), $src.PixelFormat)
$fullbleed = Resize $full 1024
Save $fullbleed 'E:\www\kele-audio\docs\images\icon_fullbleed.png'

# 3) 应用内用图（Flutter 资产）：256px 全出血
$app = Resize $fullbleed 256
Save $app 'E:\www\kele-audio\docs\images\icon_app.png'

# 4) 传统 mipmap（API<26 机型）：全出血，48dp 基准
$legacy = @{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
foreach ($k in $legacy.Keys) {
  $b = Resize $fullbleed $legacy[$k]
  Save $b ("E:\www\kele-audio\android\app\src\main\res\mipmap-{0}\ic_launcher.png" -f $k)
}

# 5) 自适应图标前景（108dp 基准，内容全出血顶满画布，掩膜外由启动器裁切）
$fg = @{ 'mdpi' = 108; 'hdpi' = 162; 'xhdpi' = 216; 'xxhdpi' = 324; 'xxxhdpi' = 432 }
foreach ($k in $fg.Keys) {
  $b = Resize $fullbleed $fg[$k]
  Save $b ("E:\www\kele-audio\android\app\src\main\res\mipmap-{0}\ic_launcher_foreground.png" -f $k)
}

$full.Dispose(); $fullbleed.Dispose(); $app.Dispose(); $src.Dispose()
Write-Output 'done'
