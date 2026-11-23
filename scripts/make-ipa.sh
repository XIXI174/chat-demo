#!/usr/bin/env bash
#
# 在 macOS 上产出一个未签名的 ChatDemo.ipa。
#
#   bash scripts/make-ipa.sh
#
# 未签名 ipa 不能直接装进手机，需要再用 Sideloadly / AltStore 以自己的
# Apple ID 重签（免费 ID 有效期 7 天）。详见仓库里的 IOS.md。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 1. 前端产物。已经同步过就跳过，避免每次重跑都装一遍依赖。
if [ ! -f "ios/ChatDemo/web/index.html" ]; then
  echo "==> 构建前端"
  pnpm install --frozen-lockfile
  NODE_ENV=production pnpm exec rspack build -c rspack.config.ts
  rm -rf ios/ChatDemo/web
  mkdir -p ios/ChatDemo/web
  cp -R dist/. ios/ChatDemo/web/
fi

# 2. 生成 Xcode 工程
cd ios
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> 安装 xcodegen"
  brew install xcodegen
fi
echo "==> xcodegen generate"
xcodegen generate

# 3. 编译（不签名，签名交给装机器时做）
echo "==> xcodebuild"
rm -rf build
xcodebuild \
  -project ChatDemo.xcodeproj \
  -scheme ChatDemo \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  -quiet \
  build

APP="build/Build/Products/Release-iphoneos/ChatDemo.app"
if [ ! -d "$APP" ]; then
  echo "编译产物不存在：$APP" >&2
  exit 1
fi

# 4. 打成 ipa
echo "==> 打包 ipa"
rm -rf out ChatDemo.ipa
mkdir -p out/Payload
cp -R "$APP" out/Payload/
(cd out && zip -qry ../ChatDemo.ipa Payload)
rm -rf out

echo "==> 完成：$ROOT/ios/ChatDemo.ipa ($(du -h ChatDemo.ipa | cut -f1))"