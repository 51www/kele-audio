#!/usr/bin/env bash
#
# kele-music iOS 一键打包脚本
# ------------------------------------------------------------
# 默认（无参数）：免签名 release 构建，并手动打成「未签名 IPA」
#                 （供归档 / 自行重签，不能直接安装到设备）
# 参数 --signed ：使用 flutter build ipa 走 Ad Hoc 正式签名
#                 （需先在 Xcode 里为 Runner 配置 Team + Ad Hoc 描述文件）
# ------------------------------------------------------------

set -euo pipefail

# 1) 环境：我们自建的 Ruby(CocoaPods) + UTF-8 locale
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export PATH="$HOME/local/ruby/bin:$PATH"

# 2) 进入项目根目录（脚本所在目录）
cd "$(cd "$(dirname "$0")" && pwd)"

# 3) 拉取 Flutter 依赖
echo "==> flutter pub get"
flutter pub get

# 4) 构建
if [ "${1:-}" = "--signed" ]; then
  echo "==> flutter build ipa --export-method=ad-hoc"
  flutter build ipa --export-method=ad-hoc
  echo "✅ 完成：build/ios/ipa/Runner.ipa（已签名，可装到已注册设备）"
  exit 0
fi

echo "==> flutter build ios --release --no-codesign"
flutter build ios --release --no-codesign

# 5) 手动打包成 IPA（Runner.app -> Payload -> zip）
APP_DIR="$PWD/build/ios/iphoneos"
APP="$APP_DIR/Runner.app"
OUT="$PWD/build/ios/ipa/Runner.ipa"

if [ ! -d "$APP" ]; then
  echo "❌ 未找到 $APP，构建可能失败" >&2
  exit 1
fi

mkdir -p "$PWD/build/ios/ipa"
rm -rf "$APP_DIR/Payload"
mkdir -p "$APP_DIR/Payload"
cp -r "$APP" "$APP_DIR/Payload/"
( cd "$APP_DIR" && rm -f "$OUT" && zip -rq "$OUT" Payload/ )

echo "✅ 完成：未签名 IPA 位于 $OUT"
echo "   说明：未签名 IPA 不能直接安装，需用 Xcode / 重签工具签名后方可装到设备。"
