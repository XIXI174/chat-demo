#!/usr/bin/env bash
# 把 chat-demo 前端构建成可托管在任意静态站的 PWA。
# Linux/macOS 版；Windows 用 scripts/build-pwa-web.ps1。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pnpm install --frozen-lockfile
NODE_ENV=production pnpm exec rspack build -c rspack.config.ts

OUT="$ROOT/pwa"
DIST="$ROOT/dist"
ICON="$ROOT/ios/ChatDemo/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$DIST/." "$OUT/"
mkdir -p "$OUT/icons"

# 图标：复用 iOS 那张 1024 PNG，用 python + Pillow 缩成多种尺寸。
# 没有 Pillow 时降级为直接复制 1024 那张（浏览器会自己缩放）。
if [ -f "$ICON" ] && python3 -c 'import PIL' 2>/dev/null; then
  python3 - "$ICON" "$OUT/icons" <<'PY'
from PIL import Image
import sys, os
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
for size in (192, 256, 384, 512):
    im.resize((size, size), Image.LANCZOS).save(os.path.join(dst, "icon-%d.png" % size), optimize=True)
PY
elif [ -f "$ICON" ]; then
  cp "$ICON" "$OUT/icons/icon-512.png"
  cp "$ICON" "$OUT/icons/icon-192.png"
fi

cat > "$OUT/manifest.webmanifest" <<'EOF'
{
  "name": "Chat Demo",
  "short_name": "ChatDemo",
  "description": "DeepSeek chat demo，装到主屏幕即可全屏运行",
  "start_url": "./",
  "scope": "./",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#4d6bfe",
  "theme_color": "#4d6bfe",
  "icons": [
    { "src": "icons/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "icons/icon-256.png", "sizes": "256x256", "type": "image/png", "purpose": "any" },
    { "src": "icons/icon-384.png", "sizes": "384x384", "type": "image/png", "purpose": "any" },
    { "src": "icons/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
  ]
}
EOF

cat > "$OUT/sw.js" <<'EOF'
const CACHE = 'chat-demo-v1';
const SHELL = ['./', './index.html', './manifest.webmanifest'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;                       // POST /messages、/files 一律直连
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;        // 跨源 API 不进缓存
  const isNav = req.mode === 'navigate' ||
                (req.headers.get('accept') || '').indexOf('text/html') !== -1;
  if (isNav) {
    // 文档走网络优先，保证发版后能拿到新版本；离线再回退首页
    e.respondWith(
      fetch(req).then((res) => {
        if (res.ok) { const c = res.clone(); caches.open(CACHE).then((x) => x.put(req, c)); }
        return res;
      }).catch(() => caches.match('./index.html'))
    );
    return;
  }
  // 静态资源缓存优先，同时后台更新（stale-while-revalidate）
  e.respondWith(
    caches.match(req).then((hit) => {
      const net = fetch(req).then((res) => {
        if (res.ok && res.type === 'basic') {
          const c = res.clone(); caches.open(CACHE).then((x) => x.put(req, c));
        }
        return res;
      }).catch(() => hit);
      return hit || net;
    })
  );
});
EOF

# 往 pwa/index.html 的 </head> 前注入 manifest / iOS 主屏幕 meta / SW 注册。
python3 - "$OUT/index.html" <<'PY'
import sys
path = sys.argv[1]
html = open(path, encoding='utf-8').read()
inject = """    <link rel="manifest" href="manifest.webmanifest">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="ChatDemo">
    <meta name="theme-color" content="#4d6bfe">
    <link rel="apple-touch-icon" href="icons/icon-192.png">
    <script>
      if ('serviceWorker' in navigator) {
        window.addEventListener('load', function () {
          navigator.serviceWorker.register('sw.js', { scope: './' }).catch(function () {});
        });
      }
    </script>
"""
if '</head>' in html:
    html = html.replace('</head>', inject + '</head>', 1)
else:
    html = inject + html
open(path, 'w', encoding='utf-8').write(html)
PY

echo "==> PWA built: $(find "$OUT" -type f | wc -l) files, $(du -sh "$OUT" | cut -f1)"
