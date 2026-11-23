#Requires -Version 5.1
<#
  把 chat-demo 前端构建成可托管在任意静态站（GitHub Pages / 对象存储 / 自有域名）的 PWA：
    1. 跑 rspack build（绕开 package.json 里 Windows 跑不了的 rm -rf dist）
    2. 往 dist/ 注入 manifest.webmanifest、service worker 注册脚本、图标
    3. 结果写进本脚本上溯两级目录下的 pwa/
  用法：powershell -ExecutionPolicy Bypass -File scripts\build-pwa-web.ps1 [-SkipInstall]
#>
param([switch]$SkipInstall)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$dist = Join-Path $root 'dist'
$out = Join-Path $root 'pwa'

Write-Host "==> 项目根目录：$root"

if (-not $SkipInstall) {
  Write-Host '==> pnpm install --frozen-lockfile'
  & pnpm install --frozen-lockfile
  if ($LASTEXITCODE -ne 0) { throw "pnpm install 失败，退出码 $LASTEXITCODE" }
}

$env:NODE_ENV = 'production'
Write-Host '==> rspack build'
& pnpm exec rspack build -c rspack.config.ts
if ($LASTEXITCODE -ne 0) { throw "rspack build 失败，退出码 $LASTEXITCODE" }

$indexHtml = Join-Path $dist 'index.html'
if (-not (Test-Path -LiteralPath $indexHtml)) { throw "构建产物里没有 $indexHtml" }

# ---------- 图标：复用 iOS 工程里那张 1024 PNG，缩成 PWA 要的几种尺寸 ----------
# 先写到临时目录；下面会清空 $out 再重建，图标最后才拷进去。
$iconSrc = Join-Path $root 'ios\ChatDemo\Assets.xcassets\AppIcon.appiconset\icon-1024.png'
$iconsTmp = Join-Path $env:TEMP 'chat-demo-pwa-icons'
if (Test-Path -LiteralPath $iconsTmp) { Remove-Item -LiteralPath $iconsTmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $iconsTmp | Out-Null
$iconsReady = $false
if (Test-Path -LiteralPath $iconSrc) {
  $py = @'
from PIL import Image
import sys, os
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGB')
for size in (192, 256, 384, 512):
    im.resize((size, size), Image.LANCZOS).save(os.path.join(dst, 'icon-%d.png' % size), optimize=True)
print('icons ok')
'@
  $pyFile = Join-Path $env:TEMP 'pwa-icons.py'
  [System.IO.File]::WriteAllText($pyFile, $py, (New-Object System.Text.UTF8Encoding($false)))
  & python $pyFile $iconSrc $iconsTmp
  if ($LASTEXITCODE -ne 0) { throw '生成 PWA 图标失败' }
  Remove-Item $pyFile -Force -ErrorAction SilentlyContinue
  $iconsReady = $true
} else {
  Write-Host "==> 警告：没找到 $iconSrc，跳过图标生成（PWA 仍可用，只是不能添加到主屏幕带图标）"
}

# ---------- 复制 dist 全部产物到 pwa/ ----------
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $out | Out-Null
Copy-Item -Path (Join-Path $dist '*') -Destination $out -Recurse -Force
if ($iconsReady) {
  Copy-Item -Path $iconsTmp -Destination (Join-Path $out 'icons') -Recurse -Force
}
Remove-Item -LiteralPath $iconsTmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------- manifest（相对 start_url / scope，兼容子路径托管） ----------
$manifest = @'
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
'@
[System.IO.File]::WriteAllText((Join-Path $out 'manifest.webmanifest'), $manifest, (New-Object System.Text.UTF8Encoding($false)))

# ---------- service worker：只缓存静态资源，不碰 api.deepseek.com 的流式响应 ----------
$sw = @'
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
'@
[System.IO.File]::WriteAllText((Join-Path $out 'sw.js'), $sw, (New-Object System.Text.UTF8Encoding($false)))

# ---------- 往 index.html 注入 manifest + SW 注册（原文件不动，改的是 pwa/ 里的副本） ----------
$indexPath = Join-Path $out 'index.html'
$html = [System.IO.File]::ReadAllText($indexPath)
$inject = @'
    <link rel="manifest" href="manifest.webmanifest">
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
'@
if ($html -match '</head>') {
  $html = $html -replace '</head>', ($inject + '</head>')
} else {
  $html = $inject + $html
}
[System.IO.File]::WriteAllText($indexPath, $html, (New-Object System.Text.UTF8Encoding($false)))

$files = (Get-ChildItem -LiteralPath $out -Recurse -File).Count
$bytes = (Get-ChildItem -LiteralPath $out -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("==> 完成：{0} 个文件，{1:N2} MB" -f $files, ($bytes / 1MB))
Write-Host "==> 产物目录：$out"
