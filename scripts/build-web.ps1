# 把前端构建产物同步进 iOS 工程。
#
# 前端是纯静态 React 应用，ispe 里不需要任何原生依赖，所以流程就是：
#   pnpm install → rspack build → 把 dist/ 整目录拷进 ios/ChatDemo/web/
#
#   powershell -ExecutionPolicy Bypass -File scripts\build-web.ps1
#
param(
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if (-not $SkipInstall) {
    Write-Host '==> pnpm install' -ForegroundColor Cyan
    pnpm install --frozen-lockfile
}

Write-Host '==> rspack build (production)' -ForegroundColor Cyan
$env:NODE_ENV = 'production'
# package.json 的 build 脚本里写了 `rm -rf dist`，在 Windows 上跑不了，直接调 rspack。
pnpm exec rspack build -c rspack.config.ts

$dist = Join-Path $root 'dist'
if (-not (Test-Path (Join-Path $dist 'index.html'))) {
    throw "构建产物缺失：$dist\index.html"
}

$target = Join-Path $root 'ios/ChatDemo/web'
Write-Host "==> 同步 dist -> $target" -ForegroundColor Cyan
if (Test-Path $target) {
    Remove-Item -Recurse -Force $target
}
Copy-Item -Path $dist -Destination $target -Recurse -Force

$files = (Get-ChildItem -Recurse -File $target).Count
$bytes = (Get-ChildItem -Recurse -File $target | Measure-Object -Property Length -Sum).Sum
Write-Host ("==> 完成：{0} 个文件，{1:N2} MB" -f $files, ($bytes / 1MB)) -ForegroundColor Green