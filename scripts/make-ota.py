#!/usr/bin/env python3
# 生成一个 iOS OTA 分发页 + manifest.plist，让客户在 Safari 里点链接装 ipa。
#
# 原理：iOS 只认 itms-services:// 协议。落地页上放一条
#   itms-services://?action=download-manifest&url=<URL-encoded HTTPS plist>
# Safari 打开这个协议会去拉 plist，plist 里的 software-package 指向 HTTPS 的
# 签名 ipa，系统校验签名 + provisioning profile 后弹出「安装」。
# 硬性要求：plist 与 ipa 的 URL 全都必须 HTTPS，HTTP 会被 iOS 直接拒。
#
# 为什么单独出一个脚本：manifest.plist 里的 bundle-identifier / bundle-version
# 必须和 ipa 内 Info.plist **逐字一致**，手抄必错。这个脚本直接从 ipa 里读。
#
# 用法（Windows / macOS / Linux 都行，只用标准库）：
#   python scripts/make-ota.py \
#     --ipa dsh-go-signed.ipa \
#     --ipa-url https://cdn.example.com/apps/dsh-go-signed.ipa \
#     --base-url https://cdn.example.com/apps \
#     --title "DSH Go" \
#     --out-dir ota
#
# 然后把 ota/ 整个目录传到 --base-url 对应的 HTTPS 静态托管，
# 把 ota/index.html 的链接发给客户即可。
#
# 渠道选择（决定要不要收 UDID）：
#   - Ad Hoc      : profile 只放行登记过 UDID 的设备 → 先让客户装 .mobileconfig 报 UDID
#   - 企业签       : 免 UDID、免设备数，点链接即装
#   - TestFlight   : 不走 OTA，直接发 TestFlight 邀请链接（免 UDID）

import argparse
import plistlib
import sys
import urllib.parse
import zipfile
from pathlib import Path


def read_ipa_metadata(ipa_path: Path) -> dict:
    """从 ipa 的 Payload/*.app/Info.plist 里抠出 OTA 需要的字段。"""
    if not ipa_path.is_file():
        sys.exit(f"ERROR: ipa 不存在：{ipa_path}")
    with zipfile.ZipFile(ipa_path) as zf:
        names = zf.namelist()
        info_names = [
            n for n in names
            if n.startswith("Payload/") and n.count("/") == 2
            and n.endswith("/Info.plist")
        ]
        if not info_names:
            sys.exit("ERROR: ipa 里找不到 Payload/*.app/Info.plist")
        # 顶层 .app 的 Info.plist（排除 Watch/Appex 子目录里的）
        info_names.sort(key=lambda n: (n.count("/"), len(n)))
        with zf.open(info_names[0]) as f:
            info = plistlib.load(f)

    return {
        "bundle_id": info.get("CFBundleIdentifier", "com.example.app"),
        "version": info.get("CFBundleShortVersionString", info.get("CFBundleVersion", "1.0")),
        "build": info.get("CFBundleVersion", "1"),
        "name": info.get("CFBundleDisplayName", info.get("CFBundleName", "App")),
        "min_os": info.get("MinimumOSVersion", "15.0"),
    }


def build_manifest(meta: dict, args) -> dict:
    """按 Apple 的 OTA manifest 结构组装 dict，plistlib 负责写 XML。"""
    return {
        "items": [{
            "assets": [
                {"kind": "software-package", "url": args.ipa_url},
                {"kind": "display-image", "needs-shine": True, "url": args.display_image_url},
                {"kind": "full-size-image", "needs-shine": True, "url": args.full_size_image_url},
                {"kind": "ipad-image", "needs-shine": True, "url": args.full_size_image_url},
            ],
            "metadata": {
                "bundle-identifier": meta["bundle_id"],
                "bundle-version": meta["version"],
                "kind": "software",
                "title": args.title or meta["name"],
                "subtitle": args.subtitle or f"v{meta['version']} · iOS {meta['min_os']}+",
            },
        }]
    }


def render_page(meta: dict, args, plist_url: str) -> str:
    itms = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(
        plist_url, safe=""
    )
    esc = lambda s: (s.replace("&", "&amp;").replace("<", "&lt;")
                      .replace(">", "&gt;").replace('"', "&quot;"))
    title = esc(args.title or meta["name"])
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>安装 {title}</title>
<style>
  * {{ box-sizing: border-box; }}
  body {{ margin:0; min-height:100vh; display:flex; align-items:center;
    justify-content:center; padding:24px; background:#0b1020; color:#e8ecf4;
    font:16px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif; }}
  .card {{ width:100%; max-width:440px; background:#151c31; border:1px solid #26304d;
    border-radius:20px; padding:28px; text-align:center; }}
  img.icon {{ width:96px; height:96px; border-radius:22px; margin-bottom:16px;
    box-shadow:0 8px 30px rgba(0,0,0,.4); }}
  h1 {{ font-size:21px; margin:0 0 4px; }}
  .meta {{ color:#8d99b8; font-size:13px; margin-bottom:24px; }}
  a.btn {{ display:block; padding:15px; border-radius:13px; text-decoration:none;
    font-size:17px; font-weight:600; background:linear-gradient(135deg,#4d6bfe,#2531ac);
    color:#fff; margin-bottom:18px; }}
  a.btn:active {{ opacity:.85; }}
  .note {{ text-align:left; color:#a9b4d0; font-size:13px; background:#101731;
    border-radius:12px; padding:14px 16px; }}
  .note b {{ color:#dbe3f7; }}
  .note ol {{ margin:8px 0 0; padding-left:20px; }}
  .note li {{ margin:4px 0; }}
  code {{ color:#7fa0ff; word-break:break-all; font-size:12px; }}
</style>
</head>
<body>
<div class="card">
  <img class="icon" src="{esc(args.display_image_url)}" alt="icon">
  <h1>{title}</h1>
  <div class="meta">版本 {esc(meta['version'])} ({esc(meta['build'])}) · iOS {esc(meta['min_os'])} 及以上</div>
  <a class="btn" href="{esc(itms)}">点此安装到 iPhone / iPad</a>
  <div class="note">
    <b>安装须知</b>
    <ol>
      <li>必须用 <b>iPhone 自带 Safari</b> 打开本页，微信 / QQ 内置浏览器不行。</li>
      <li>点上面按钮 → 弹「是否安装」→ 点<b>安装</b>，桌面出现图标即在装。</li>
      <li>首次打开若提示「未受信任的企业级开发者」：设置 → 通用 → VPN 与设备管理 → 信任该证书。</li>
      <li>Ad Hoc 签名只对已登记 UDID 的设备有效；企业签 / TestFlight 免这一步。</li>
      <li>装好后进「设置」填自己的 API Key 即可对话，Key 只留在本机。</li>
    </ol>
  </div>
  <p style="margin-top:18px"><code>{esc(plist_url)}</code></p>
</div>
</body>
</html>
"""


def main() -> None:
    p = argparse.ArgumentParser(description="生成 iOS OTA manifest.plist + 落地页")
    p.add_argument("--ipa", required=True, help="已签名 ipa（用来读 bundle-id / version）")
    p.add_argument("--ipa-url", required=True, help="签名 ipa 的 HTTPS 直链")
    p.add_argument("--base-url", required=True, help="OTA 静态目录的 HTTPS 根地址")
    p.add_argument("--title", default="", help="显示名，默认取 ipa 的 CFBundleDisplayName")
    p.add_argument("--subtitle", default="", help="副标题")
    p.add_argument("--out-dir", default="ota", help="输出目录，默认 ota/")
    args = p.parse_args()

    for label, url in (("--ipa-url", args.ipa_url), ("--base-url", args.base_url)):
        if not url.startswith("https://"):
            sys.exit(f"ERROR: {label} 必须是 HTTPS，iOS 不认 HTTP：{url}")

    base = args.base_url.rstrip("/")
    args.display_image_url = f"{base}/icon-57.png"
    args.full_size_image_url = f"{base}/icon-512.png"

    meta = read_ipa_metadata(Path(args.ipa))
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    manifest = build_manifest(meta, args)
    plist_path = out / "manifest.plist"
    with plist_path.open("wb") as f:
        plistlib.dump(manifest, f, fmt=plistlib.FMT_XML, sort_keys=True)

    plist_url = f"{base}/manifest.plist"
    page = render_page(meta, args, plist_url)
    (out / "index.html").write_text(page, encoding="utf-8")

    # 图标占位：让脚本自动产出可直接用的 57/512 PNG（有 Pillow 就画，没有就留空文件提示）。
    make_icons(out)

    print("==> 已生成")
    print(f"    {out / 'index.html'}")
    print(f"    {plist_path}")
    print(f"    {out / 'icon-57.png'} / {out / 'icon-512.png'}")
    print(f"==> bundle-identifier = {meta['bundle_id']}")
    print(f"==> bundle-version    = {meta['version']}")
    print(f"==> itms-services url = {plist_url}")
    print(f"==> 把 {out}/ 整个目录传到 {base}，把 index.html 的链接发给客户")


def make_icons(out: Path) -> None:
    """优先复用仓库的 1024 图标缩放；没 Pillow 就写一个 1x1 占位并提示替换。"""
    src = Path(__file__).resolve().parent.parent / "ios/ChatDemo/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    try:
        from PIL import Image
        if src.is_file():
            im = Image.open(src).convert("RGB")
            im.resize((57, 57), Image.LANCZOS).save(out / "icon-57.png")
            im.resize((512, 512), Image.LANCZOS).save(out / "icon-512.png")
            return
        for size in (57, 512):
            Image.new("RGB", (size, size), (77, 107, 254)).save(out / f"icon-{size}.png")
        print("    NOTE: 没找到仓库 1024 图标，用了纯色占位，记得换成自己的 App 图标")
    except ImportError:
        for size in (57, 512):
            (out / f"icon-{size}.png").write_bytes(b"")
        print("    NOTE: 没装 Pillow，icon-*.png 是空占位，请自己放 57x57 / 512x512 PNG")


if __name__ == "__main__":
    main()
