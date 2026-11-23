#!/usr/bin/env bash
# 重签一个未签名 ipa，产出可点链接安装的签名包。
# macOS only：codesign / PlistBuddy / security 都在 Xcode 工具链里。
#
# 为什么需要这个脚本：dsh-Go 的 iOS Release 是 unsigned ipa（126 MB，内含
# DshFlock.framework / DshRequireBuiltin.framework / DshNodeHost.framework，
# 可选 DshGuest.framework，以及 ShareExtension.appex）。iOS 的签名校验是
# 自外向内的：任何一个嵌套 framework 没签妥，主 App 启动时直接
# "code signature invalid" 闪退。所以顺序必须是「先子后父」，不能一把
# --deep 梭哈（--deep 不处理 entitlements 与 App Group 对齐）。
#
# 用法：
#   scripts/resign-ipa.sh \
#     --ipa dsh-go-1.3.0-ios-unsigned.ipa \
#     --cert "Apple Distribution: Your Name (TEAMID)" \
#     --profile path/to/AdHoc.mobileprovision \
#     --out dsh-go-signed.ipa
#
# 证书名用 `security find-identity -v -p codesigning` 查。
# entitlements 从 --profile 里现抽（Ad Hoc / 企业签够用）。
# 要改 Bundle ID 时另传 --bundle-id com.example.dshgo，并自行同步
# entitlements 里的 application-identifier / App Group 前缀。

set -euo pipefail

IPA=""
CERT=""
PROFILE=""
OUT=""
BUNDLE_ID=""

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipa)          IPA="$2"; shift 2 ;;
    --cert)         CERT="$2"; shift 2 ;;
    --profile)      PROFILE="$2"; shift 2 ;;
    --out)          OUT="$2"; shift 2 ;;
    --bundle-id)    BUNDLE_ID="$2"; shift 2 ;;
    -h|--help)      sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$IPA" && -f "$IPA" ]]         || die "--ipa 指向一个存在的未签名 ipa"
[[ -n "$CERT" ]]                     || die "--cert 不能为空"
[[ -n "$PROFILE" && -f "$PROFILE" ]] || die "--profile 指向一个存在的 .mobileprovision"
[[ -n "$OUT" ]]                      || die "--out 不能为空"
command -v codesign >/dev/null       || die "需要 macOS + Xcode 命令行工具（codesign 不存在）"
command -v zip >/dev/null            || die "需要 zip"

# 输出一律转成绝对路径：下面要 cd 进临时目录再打包，相对路径会打错地方。
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
OUT_ABS="$OUT_DIR/$(basename "$OUT")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "1/7 解包 $IPA"
mkdir -p "$WORK/payload"
unzip -q "$IPA" 'Payload/*' -d "$WORK/payload"
APP="$(find "$WORK/payload/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP" ]] || die "ipa 里找不到 Payload/*.app"

log "2/7 从 profile 抽出 entitlements"
security cms -D -i "$PROFILE" > "$WORK/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/entitlements.plist"
[[ -s "$WORK/entitlements.plist" ]] || die "profile 里没有 Entitlements 字段"

log "3/7 埋入 embedded.mobileprovision"
cp "$PROFILE" "$APP/embedded.mobileprovision"

if [[ -n "$BUNDLE_ID" ]]; then
  log "4/7 改 Bundle ID → $BUNDLE_ID"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
  find "$APP" -type d -name '*.appex' -print0 | while IFS= read -r -d '' EXT; do
    OLD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXT/Info.plist")"
    SUFFIX="${OLD##*.}"
    NEW="${BUNDLE_ID}.${SUFFIX}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW" "$EXT/Info.plist"
    log "    $OLD → $NEW"
  done
  log "    NOTE: entitlements 里的 application-identifier / App Group / keychain-access-groups"
  log "          请自行改成 <TEAM_ID>.${BUNDLE_ID} 前缀，脚本不猜你的 Team ID。"
else
  log "4/7 保持原 Bundle ID"
fi

log "5/7 由深到浅签所有嵌套 framework / appex / watch / xpc"
# 按路径斜杠数倒序：子目录排在父目录前面，先子后父。
find "$APP" -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.watch' -o -name '*.xpc' \) \
  | awk '{ n=gsub(/\//,"/"); print n "\t" $0 }' \
  | sort -k1,1nr \
  | cut -f2- \
  | while IFS= read -r NODE; do
      echo "    sign $NODE"
      # 嵌套代码不套主 App 的 entitlements：带错前缀会被 amfid 拒。
      codesign --force --sign "$CERT" \
        --preserve-metadata=identifier,requirements,flags \
        --timestamp=none "$NODE"
    done

log "6/7 签主 App（带 entitlements）"
codesign --force --sign "$CERT" \
  --entitlements "$WORK/entitlements.plist" \
  --timestamp=none \
  "$APP"

log "7/7 校验 + 重新打包"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -20
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority|Identifier|TeamIdentifier' || true
rm -f "$OUT_ABS"
(cd "$WORK/payload" && zip -qryX "$OUT_ABS" Payload)
[[ -f "$OUT_ABS" ]] || die "打包失败，没生成 $OUT_ABS"
log "完成：$OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
log "下一步：python scripts/make-ota.py 生成 manifest.plist + 落地页"
