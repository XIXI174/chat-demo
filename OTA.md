# OTA 分发：让异地的 iPhone 点链接装「真原生」ipa

> 适用场景：iPhone 不在你手边（客户在北京、你在河南），又没有 Apple 开发者账号，
> 或者客户装的是 TrollStore 之外的普通 iOS。本文讲**付费签名 + 点链接安装**这条
> 唯一能远程交付真原生 App 的路，以及它的三个替代渠道。

## 为什么必须走这一步

iOS 只装 Apple 认可签名的 Mach-O。我们（以及 dsh-Go 官方 Release）产出的 ipa
都是 **unsigned**，直接发给客户装不上。远程装只有三条路：

| 渠道 | 是否要电脑 | 是否要续签 | 是否免 UDID | 前置条件 |
|---|---|---|---|---|
| **A. App Store / TestFlight**（见 [IOS.md](IOS.md) 首选节） | 不要 | 不要 | 是 | 应用已上架 / 有 TestFlight 名额 |
| **B. 付费签名 + OTA（本文）** | 不要 | 不要 | Ad Hoc 要 / 企业签不要 | `$99/年` 开发者账号 + 证书 + profile |
| **C. TrollStore** | 不要 | 不要 | 是 | 客户 iOS ≤ 17.0（17.0.1 起漏洞已修） |
| D. Sideloadly 自装 | **要 USB 连电脑** | 7 天 | 是 | 客户手边有电脑 + 免费 Apple ID |

人机分离时 D 直接出局；A 最省事但要等上架；B 是「我现在就要把 dsh-Go 发给客户」
的可控做法；C 看客户系统版本撞运气。

## 前置材料（B 线）

1. Apple Developer Program `$99/年`（或企业账号 `$299/年`）。
2. `Apple Distribution` 证书，导入 Mac 钥匙串；`security find-identity -v -p codesigning` 能看到。
3. `.mobileprovision`：
   - **Ad Hoc**：需在开发者后台登记客户设备 UDID（发一个 `.mobileconfig` 让客户用 Safari 装，
     回传 UDID 后加进设备列表再重新生成 profile）。最多 100 台/年，点链接前必须登记。
   - **企业签（In-House）**：免 UDID、免设备数，客户点开即装，首次要手动「信任企业级开发者」。
4. 一个 **HTTPS** 静态托管（GitHub Pages / Cloudflare Pages / 对象存储 + CDN 都行），
   用来放 `manifest.plist`、`index.html`、图标和签名后的 ipa。
   **plist 与 ipa 的 URL 必须全是 HTTPS**，HTTP 会被 iOS 直接拒。

## 步骤 1：重签 ipa

dsh-Go 的 iOS 包包了 `DshFlock.framework` / `DshRequireBuiltin.framework` /
`DshNodeHost.framework`（可选 `DshGuest.framework`）和 `ShareExtension.appex`。
iOS 签名校验自外向内，任何一个嵌套 framework 没签妥，主 App 启动就
`code signature invalid` 闪退。所以必须**先签嵌套、再签主 App**，不能 `--deep` 一把梭。

```bash
# 在 macOS 上，装好 Xcode 命令行工具后
scripts/resign-ipa.sh \
  --ipa dsh-go-1.3.0-ios-unsigned.ipa \
  --cert "Apple Distribution: Your Name (TEAMID)" \
  --profile path/to/AdHoc.mobileprovision \
  --out dsh-go-signed.ipa
# 需要改 Bundle ID 时加： --bundle-id com.yourteam.dshgo
```

脚本会：解包 → 从 profile 抽 entitlements → 埋 `embedded.mobileprovision` →
按路径深度由深到浅签所有 framework/appex → 带 entitlements 签主 App →
`codesign --verify --deep --strict` 自检 → 重打包。
改了 Bundle ID 记得同步 entitlements 里的 `application-identifier` / App Group /
`keychain-access-groups` 前缀，脚本只提示不代猜 Team ID。

> 我们自己的 `ChatDemo-unsigned.ipa` 走同一脚本即可；若已配齐
> `.github/workflows/ios.yml` 里的 5 个 secret，CI 会直接产出 `ChatDemo-signed.ipa`，
> 这步可跳过。

## 步骤 2：生成 OTA 落地页

`manifest.plist` 里的 `bundle-identifier` / `bundle-version` 必须和 ipa 内
`Info.plist` **逐字一致**，手抄必错。`make-ota.py` 直接从 ipa 里读：

```bash
python scripts/make-ota.py \
  --ipa dsh-go-signed.ipa \
  --ipa-url https://cdn.example.com/apps/dsh-go-signed.ipa \
  --base-url https://cdn.example.com/apps \
  --title "DSH Go" \
  --out-dir ota
```

产出 `ota/manifest.plist`、`ota/index.html`、`ota/icon-57.png`、`ota/icon-512.png`。
把 `ota/` 整个目录传到 `--base-url` 对应的 HTTPS 根，把签名 ipa 也放到 `--ipa-url`。

## 步骤 3：发给客户

把 `https://cdn.example.com/apps/index.html` 发给客户，让对方：

1. 用 **iPhone 自带 Safari** 打开（微信/QQ 内置浏览器不认 `itms-services://`）。
2. 点「点此安装到 iPhone / iPad」→ 弹窗点「安装」。
3. 首次打开若提示「未受信任的企业级开发者」：设置 → 通用 → VPN 与设备管理 → 信任。
4. 装好进「设置」填自己的 API Key 即可对话。

`index.html` 里那条链接本质是：

```
itms-services://?action=download-manifest&url=<URL-encoded HTTPS plist>
```

## 验收

- Mac 上 `codesign -dv --verbose=4 dsh-go-signed.ipa`（先解包）显示
  `Authority=Apple Distribution`、`TeamIdentifier=<你的 Team ID>`。
- `codesign --verify --deep --strict Payload/*.app` 无输出即通过。
- 客户冷启动 3 次不闪退、能填 Key、能跑一次流式对话。
- Ad Hoc：确认客户 UDID 在 profile 的 `ProvisionedDevices` 里，否则点安装报
  「无法安装，因为无法验证其完整性」。

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| Safari 点按钮没反应 | 不是 HTTPS / 用了微信内置浏览器 | 换 HTTPS + 系统 Safari |
| 「无法连接到 xxx」 | plist 或 ipa 404 | 核对 `--base-url` 与 `--ipa-url` 实际可匿名下载 |
| 「无法安装，无法验证完整性」 | 嵌套 framework 漏签 / UDID 没登记 / profile 与证书不匹配 | 用 `resign-ipa.sh` 重签；Ad Hoc 补 UDID |
| 装完点开秒退 | `LC_BUILD_VERSION` 是模拟器构建 / 嵌套 framework 签名无效 | 用真机 device 包；查 `codesign --verify` |
| 提示「未受信任的企业级开发者」 | 企业签首次安装 | 设置里手动信任，正常现象 |
| 7 天后打不开 | 用了免费 Personal Team 签的 | 换付费 Distribution 证书重签，或走渠道 A |

## 边界

- 这条线给的是 **DSH Harness 引擎客户端**（dsh-Go / Fish Pocket 那一类），不是
  chat-demo 前端；客户只要 chat-demo 界面仍用已交付的 ipa / PWA。
- Ad Hoc 每台设备都要先收 UDID；企业签和 TestFlight 不用。
- 免费 Personal Team 是 7 天 / 3 台 / 无推送，达不到「零续签」验收，别拿它交付客户。
