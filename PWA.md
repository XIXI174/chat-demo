# 远程 iPhone 安装方案：PWA（推荐）

> **先说清楚 PWA 是什么，免得踩坑**：PWA 和直接访问 `https://cdn.deepseek.com/chat-demo`
> 是**同一份前端**——两边 `static/js/main.4fc5bb07.js` 都是 477,569 字节、
> SHA256 都是 `C4C9FB2A55C452BB4B31780DF5C2D565C2583312B39A2876EA171755ED112855`，
> 逐字节相同。PWA 只是多加了 manifest（standalone 全屏）、Service Worker（离线壳）
> 和主屏图标，**本质仍是网页，不是原生程序**。
>
> 想要「真原生 App」，看这两条：
> - **省事**：用现成的原生客户端 [Fish Pocket / dsh-Go 对比与首选节](<IOS.md>)，
>   客户 App Store 点一下装好，零签名零续签。
> - **要自己那个 ipa / 要 dsh-Go 牌子**：`ChatDemo-unsigned.ipa` 里
>   `Payload/ChatDemo.app/ChatDemo` 本来就是编译好的 ARM64 Mach-O 原生可执行程序
>   （`magic 0xfeedfacf`、`platform 2` 真机 iOS 15.0+）。它装不上异地手机的唯一关卡
>   是 **Apple 签名规则**，不是技术做不到。远程点链接安装走 [OTA.md](<OTA.md>)：
>   付费签名 → 重签 → `itms-services://` 落地页。
>
> PWA 的价值在于「零门槛、零成本、发个网址就能用」；要原生体验就别指望 PWA。

## 为什么不用 ipa

`ChatDemo-unsigned.ipa` 是**未签名**包，安装前提是 Sideloadly + 数据线把 iPhone 连到电脑，用客户的 Apple ID 重签（免费 ID 7 天过期，还要在手机上点「信任开发者」）。

现在手机在北京、你在河南，人机分离——USB 连不上、7 天到期也没法插线续签。硬走这条路只有两个变体，都不省事：

1. **客户自己装 Sideloadly + iTunes**，自己用他的 Apple ID 重签。等于把整套流程远程教给客户，还要他给你他的 Apple ID/专用密码，或者他自己操作。
2. **换成付费签名**（$99/年开发者账号 → Ad Hoc / TestFlight / 企业签），出一个客户点链接就能装的 ipa。要钱、要审核、要收集客户 UDID，且企业签有被吊销风险。这条路的完整落地脚本见 [OTA.md](<OTA.md>)（`resign-ipa.sh` + `make-ota.py`），它才是「远程装真原生 App」的正解，本文 PWA 只是不想办账号时的替代。

**最省事的是绕开 ipa**：这个 App 本质是一套静态前端（React + Rspack），功能全在网页里，原生壳只提供了本地 HTTP origin 和下载/预览桥接。把它托管到一个 HTTPS 网址，客户用 Safari 打开、点「添加到主屏幕」，得到一个全屏、有图标、能离线打开壳资源的 App——**不用签名、不用电脑、不用 App Store、不用 7 天续签、跨国照样能用**。

## 原理：为什么网页能顶替原生壳

原生壳里那个 `127.0.0.1` 本地服务器只解决一件事：给页面一个 **secure context**，让 IndexedDB、`getUserMedia`、Service Worker 能用（`file://` 下这些全废）。

换成 `https://<域名>/pwa/` 之后：

| 能力 | 本地壳（http://127.0.0.1） | PWA（https 域名） |
|---|---|---|
| IndexedDB / localStorage | ✅ | ✅ |
| `getUserMedia` 语音输入 | ✅ | ✅（Safari 需 HTTPS） |
| Service Worker / 离线壳 | — | ✅ |
| DeepSeek API 直连 | ✅（CORS 实测 200） | ✅（CORS 实测 200） |
| 会话数据持久化 | App 沙盒 | 浏览器站点存储 |

**CORS 已实测**：`OPTIONS https://api.deepseek.com/anthropic/v1/messages` 带 `Origin: https://xixi174.github.io` 返回 `200`，回显 `access-control-allow-origin: https://xixi174.github.io`、`access-control-allow-headers: x-api-key,anthropic-beta,content-type,accept`、`access-control-allow-methods: POST`。也就是说前端在 GitHub Pages 上照样能直接流式调 DeepSeek，不需要任何代理。

**Pages 归属**：仓库里现在有两条 web 相关 workflow。旧的 `Deploy GitHub Pages` 已改名为 `Check Web (type + lint)`，只跑类型检查 + lint + 一次构建、不再部署；`Deploy PWA` 是 `github-pages` 环境的唯一部署方，PWA 放在站点根路径。两条 workflow 抢同一个环境会互相覆盖根站点，必须只留一个部署方。

## 交付物

| 文件 | 说明 |
|---|---|
| `https://xixi174.github.io/chat-demo/` | **直接发给客户的链接**（Pages 根路径，已上线验证 200） |
| `ChatDemo-PWA.zip` | 同上内容的离线 zip，公开下载：`https://github.com/XIXI174/chat-demo/releases/download/ios-v1.0.0/ChatDemo-PWA.zip`（1,957,358 字节，164 entries） |
| `scripts/build-pwa-web.ps1` | Windows 本机构建（已验证：159 文件 / 4.24 MB） |
| `scripts/build-pwa-web.sh` | Linux/macOS/CI 构建 |
| `.github/workflows/pwa.yml` | CI：构建 → 出 `ChatDemo-PWA.zip` artifact → 发到 GitHub Pages（该环境的唯一部署方） |
| `pwa/` | 本地构建产物（不入库） |

构建脚本做的事：

1. 跑 `rspack build`（绕开 `package.json` 里 Windows 跑不了的 `rm -rf dist`）
2. 复制 `dist/` 到 `pwa/`
3. 复用 `ios/ChatDemo/Assets.xcassets/AppIcon.appiconset/icon-1024.png` 生成 192/256/384/512 四种 PWA 图标
4. 写 `manifest.webmanifest`（`display: standalone`、`start_url: "./"`、`scope: "./"`，相对路径兼容子目录托管）
5. 写 `sw.js`：文档网络优先（发版能更新）、静态资源 stale-while-revalidate、离线回退 `index.html`；**所有 POST 与跨源 `api.deepseek.com` 请求一律不进缓存**，SSE 流式响应不受影响
6. 往 `index.html` 的 `</head>` 注入 manifest、iOS 主屏幕 meta（`apple-mobile-web-app-capable`）、`apple-touch-icon`、Service Worker 注册

## 使用步骤

### 方式 A：走 GitHub Pages（免费、已配好）

1. 把仓库推到 `main`，`Deploy PWA (remote iPhone install)` 这条 workflow 会自动跑
2. 跑完后打开 **https://xixi174.github.io/chat-demo/**（PWA 直接放站点根路径）
3. 把这条链接发给北京的客户，让他在 **iPhone 的 Safari** 里打开（微信内置浏览器不行，必须 Safari）
4. 点底部「分享」→ **添加到主屏幕** → 确认
5. 主屏幕出现「ChatDemo」图标，点开就是全屏、无地址栏的 App
6. 首次进「设置」填 `sk-` 开头的 DeepSeek API Key，发消息验证流式输出

### 方式 B：自己托管

拿 CI 的 `ChatDemo-PWA.zip`（或本地 `pwa/` 目录）传到任意支持 HTTPS 的静态托管：Cloudflare Pages、Vercel、Netlify、阿里云 OSS + CDN、自有服务器 nginx 都行。唯一硬性要求 **HTTPS**（Service Worker、`getUserMedia` 都要 secure context）。`manifest` 用相对路径，放子目录也能用。

### 方式 C：客户手上有 Mac / 会装 Sideloadly

那就回到 [IOS.md](<IOS.md>) 的 Sideloadly 流程，把 `ChatDemo-unsigned.ipa` 发给他自己签。7 天到期他自己插线重签一次。

## 已知边界（PWA vs 原生 ipa）

- **没有原生分享面板**：网页里导出 ZIP 走浏览器下载（Safari 的「下载项」），不是 `UIActivityViewController`。
- **文件导入**：走 `<input type=file>` 的浏览器默认选择器，能选「文件」App 和照片，够用。
- **没有推送 / 后台常驻**：和 ipa 一样，切后台长回答会被挂起，建议留前台。
- **TTS 朗读**：仍需用户点击手势触发（Web Audio 限制），iOS Safari 上和壳里一致。
- **会话数据存在浏览器站点存储里**：客户清 Safari 网站数据会清掉；不要清就不会丢。
- **图标名**：主屏幕显示 `ChatDemo`（`manifest.short_name`），想改成中文改 `short_name` 即可。

## 排错

| 现象 | 处理 |
|---|---|
| 添加到主屏幕后还是有地址栏 | 必须用 **Safari** 打开并添加；微信/QQ 内置浏览器添加的是书签，不是 standalone |
| 打开白屏 | 确认网址是 HTTPS；确认 `static/js/main.*.js` 能 200；清一次 Safari 缓存 |
| 发消息报网络错误 | API Key 无效；或在「设置」里点测试按钮看 `/models` 能否通过 |
| 语音输入没反应 | 确认 HTTPS + Safari 里允许麦克风；PWA 首次会弹权限 |
| 更新后还是旧界面 | 文档是网络优先，杀掉主屏幕 App 重开一次；还不行就删掉图标重新添加 |
| 国内访问 github.io 慢/打不开 | 用方式 B 把 `ChatDemo-PWA.zip` 传到国内可直连的 HTTPS 托管 |
