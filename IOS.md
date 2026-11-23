# iOS 版 Chat Demo

把 [deepseek-ai/chat-demo](https://github.com/deepseek-ai/chat-demo) 这个官方网页 demo 装进 iPhone 的方案。

前端代码**一行没改**，iOS 侧只加了一个原生壳（`ios/`）：它启动一个只监听 `127.0.0.1` 的本地静态服务器，用 `WKWebView` 打开页面，再把网页在浏览器里有、在 WebView 里没有的能力接回原生。

---

## 为什么要套壳，而不是直接打包网页

直接把 `dist/` 塞进 `WKWebView` 用 `file://` 打开会坏在三个地方：

| 能力 | `file://` | `http://127.0.0.1` |
| --- | --- | --- |
| IndexedDB（会话、图片存储） | 抛 `SecurityError` | 正常 |
| `getUserMedia`（语音输入） | 不是 secure context，直接不可用 | 正常 |
| 相对路径异步 chunk 加载 | 依赖 `publicPath: auto`，容易断 | 正常 |

`127.0.0.1` 属于 loopback，WebKit 把 loopback origin 视为 potentially trustworthy，所以 secure context 的那套判定全部通过。这就是壳里那 200 行 `LocalServer.swift` 存在的唯一理由。

顺带一个好处：页面 origin 是 `http://127.0.0.1:<端口>`，而 DeepSeek API 的 CORS 允许这个 origin（已实测 `OPTIONS` 返回 200 并回显 `access-control-allow-origin`），所以 **API 直连，不需要原生网络层代理**。

---

## 目录

```
ios/
  project.yml                  # XcodeGen 工程描述（不提交 .xcodeproj）
  ChatDemo/
    AppDelegate.swift          # 入口 + 音频会话
    SceneDelegate.swift
    WebViewController.swift    # WKWebView 宿主：录音、选文件、下载、新窗口
    LocalServer.swift          # 127.0.0.1 静态服务器
    BridgeScript.swift         # 注入网页的原生桥
    Info.plist
    Assets.xcassets/AppIcon…   # 图标由脚本生成
    web/                       # 前端构建产物（构建时生成，不入库）
scripts/
  generate-icon.py             # 用 Pillow 画 1024 图标
  build-web.ps1                # Windows：构建前端并同步进 ios/
  make-ipa.sh                  # macOS：出未签名 ipa
.github/workflows/ios.yml      # macOS runner 自动出包
```

### 桥接实现的能力

| 网页行为 | 浏览器里 | 壳里 |
| --- | --- | --- |
| `<a download>` 导出会话 ZIP | 落盘 | 写临时文件 + 系统分享面板（可存「文件」或 AirDrop） |
| 附件图片/PDF 点开新标签 | 新标签预览 | `QLPreviewController` 原生预览 |
| `<input type=file>` 导入会话 | 文件选择器 | `UIDocumentPickerViewController` |
| 正文里的外部链接 | 新标签 | `SFSafariViewController` 应用内浏览器 |
| 语音输入 `getUserMedia` | 授权后可用 | 系统麦克风授权后可用 |
| 长按图片「存储图像」 | 系统菜单 | 转成分享面板 |

前端源码零改动，全部靠 `BridgeScript.swift` 注入脚本 + `WKUIDelegate` 拦下来。

---

## 出包

### 路线 A：GitHub Actions（不需要 Mac，推荐）

1. fork 本仓库，或者把这份代码推到自己的 GitHub 仓库（公开仓库的 macOS runner 免费）。
2. 仓库 → **Actions** → 左侧 **Build iOS IPA** → **Run workflow**。
3. 等 5~10 分钟，在跑完的那次 run 底部下载 artifact：
   - 没配签名 secret → `ChatDemo-unsigned`，里面 `ChatDemo-unsigned.ipa`
   - 配了 → `ChatDemo-signed`，可直接装
   - `ChatDemo-simulator` → `ChatDemo-simulator.zip`，给 Appetize 这类在线模拟器用（见「没有 iPhone」一节）

**注意**：`ChatDemo-unsigned.ipa` 是 device 构建（Mach-O `platform 2`），`ChatDemo-simulator.zip` 里的 `ChatDemo.app` 是 Simulator 构建（fat：x86_64 + arm64，`platform 7`）。两者二进制平台标记不同，不能互相改名顶替——ipa 传进模拟器起不来，simulator .app 也装不进真机。workflow 里用 `-destination 'generic/platform=iOS Simulator'` + `ARCHS="arm64 x86_64"` 单独编的。

如果要出**能直接装**的 ipa，在仓库 Secrets 里配这 5 个：

| Secret | 内容 |
| --- | --- |
| `APPLE_CERT_P12` | 签名证书 `.p12` 的 base64 |
| `APPLE_CERT_PASSWORD` | `.p12` 密码 |
| `APPLE_PROFILE` | `.mobileprovision` 的 base64 |
| `APPLE_TEAM_ID` | 10 位 Team ID |
| `APPLE_PROFILE_NAME` | profile 的 Name 字段（`PlistBuddy -c 'Print :Name'`） |

base64 生成：`base64 -i cert.p12 | pbcopy`（macOS）。

> Ad Hoc 类型的 profile 只对 profile 里登记过 UDID 的设备有效。给朋友装就得把对方 UDID 加进去，这是 Apple 的规则，不是壳的限制。

### 路线 B：自己的 Mac

```bash
# 0. 前置
brew install pnpm xcodegen

# 1. 前端 + 同步
pnpm install --frozen-lockfile
NODE_ENV=production pnpm exec rspack build -c rspack.config.ts
rm -rf ios/ChatDemo/web && mkdir -p ios/ChatDemo/web && cp -R dist/. ios/ChatDemo/web/

# 2. 一键出未签名 ipa
bash scripts/make-ipa.sh
# → ios/ChatDemo.ipa
```

`make-ipa.sh` 会自己判断前端产物在不在，缺了就补构建，然后 `xcodegen generate` + `xcodebuild archive` + 打 zip。

想在 Xcode 里跑模拟器/真机调试：

```bash
cd ios && xcodegen generate && open ChatDemo.xcodeproj
```

真机调试需要在 Xcode 的 Signing & Capabilities 里选自己的 Team，Bundle Identifier 改成自己唯一的（比如 `com.yourname.chatdemo`）。

### 路线 C：Windows 上能做什么

这台 Windows 机器**不能**产出 ipa（没有 Xcode，`actool`/`codesign` 只在 macOS）。能做的部分：

```powershell
# 1. 构建前端并同步进 ios/（已验证：153 个文件，4.19 MB）
powershell -ExecutionPolicy Bypass -File scripts\build-web.ps1

# 2. 生成图标
python scripts\generate-icon.py
```

然后走路线 A，把仓库推到 GitHub 让它出包。

---

## 装到 iPhone

### 未签名 ipa

未签名 ipa 不能直接点开安装，必须用个人 Apple ID 重签：

> **iPhone 不在身边（异地/远程客户）别走这条**：Sideloadly 要 USB 连电脑，7 天到期还得再插一次线。改用 [PWA.md](<PWA.md>) 的 HTTPS PWA 方案——发个网址，客户 Safari 打开点「添加到主屏幕」即可，无需签名、无需电脑、无需续签。

1. Windows 装 [Sideloadly](https://sideloadly.io/)（需要 iTunes / Apple Devices 驱动）。
2. 把 `ChatDemo-unsigned.ipa` 拖进去，填 Apple ID，点 Start。
3. 手机上「设置 → 通用 → VPN与设备管理」信任开发者证书。
4. 首次启动会要求输入 API Key。

**免费 Apple ID 签的包 7 天过期**，过期后重跑一次 Sideloadly 即可，数据不丢（会话存在 App 的 IndexedDB 里，重签覆盖安装不会清）。

### 已签名 ipa

- Ad Hoc：用 Apple Configurator / Xcode Devices 装，或者托管的 OTA 分发页。
- 企业签名 / TestFlight：走正常分发流程。

---

### 没有 iPhone：在线模拟器（Appetize.io）

真机之外还有一条验收路：把 **Simulator 构建**的 `.app` 打成 zip 传进 [Appetize.io](https://appetize.io/)。

1. 下 `ChatDemo-simulator.zip`（Release `ios-v1.0.0` 里有，或自己跑 CI 拿 `ChatDemo-simulator` artifact）。
2. 上传时 **不要解压**，zip 顶层就是 `ChatDemo.app/`（无 `__MACOSX`）。Appetize 只收 `.zip` / `.tar.gz`。
3. 设备选 `iphone14pro`，系统 `17.2`，点 Start。

能验收：界面、深色模式、Markdown/公式/Mermaid、填 API Key、流式对话、会话持久化。
不能验收：语音输入（模拟器无麦克风，`getUserMedia` 拿不到设备）、TTS 声音（走宿主音频，时有时无）、真机性能。免费计划每月 30 分钟。

ipa 里是 device 构建（arm64，`platform 2`），**传进模拟器跑不起来**，必须用 simulator 那份。

---

## 首次启动要做的事

1. 打开 App，进「设置」，填 DeepSeek API Key（`sk-` 开头，[platform.deepseek.com](https://platform.deepseek.com) 申请）。
2. 允许麦克风（用语音输入时需要），拒绝也不影响打字。
3. 想用联网搜索/文件上传模型时按页面提示操作。

---

## 已知限制

这些是 iOS 平台本身的边界，不是没做完：

- **没有推送**。WebView 里没有 APNs，App 不在前台就不会有通知。
- **没有后台常驻**。切后台后请求可能被挂起，长回答建议留在前台。
- **TTS 朗读**需要点击后触发（Web Audio 的用户手势要求），这和 Safari 里一样。
- **文件导入**走 WebKit 默认文件选择器（iOS 会弹「照片图库 / 选取文件」），只能选「文件」App 里能看到的文件。
- **分享/保存**走系统分享面板，想存到「照片」需要在面板里选对应动作。
- 未签名包 7 天到期是 Apple 的免费 ID 规则。

---

## 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| 白屏，提示「安装包里没有前端资源」 | `ios/ChatDemo/web/` 是空的，先跑 `build-web.ps1` / `make-ipa.sh` |
| 白屏，提示「本地服务启动失败」 | 沙盒/端口问题；重启 App。多次失败说明 `LocalServer` 拿不到端口，提 issue |
| 语音输入按钮点了没反应 | 检查麦克风权限；iOS 设置 → Chat Demo → 麦克风 |
| 发消息报网络错误 | API Key 无效，或者网络被拦。先用「设置」里的测试按钮验证 key |
| 导出的 ZIP 存不下来 | 系统分享面板里选「存储到文件」，别选空的动作 |
| CI 里 `xcodegen` 找不到 | workflow 会自动 `brew install xcodegen`，检查那一步日志 |

---

## 版本

- 前端：跟随上游 `deepseek-ai/chat-demo` `main`
- 壳：`MARKETING_VERSION 1.0.0`，`CURRENT_PROJECT_VERSION 1`（在 `ios/project.yml` 里改）
- Bundle ID：`com.deepseek.chatdemo`（自己签名时改成唯一的）
- 最低系统：iOS 15.0