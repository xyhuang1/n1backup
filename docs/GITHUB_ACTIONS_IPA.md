# 用 GitHub Actions 打 IPA（无需自己的 Mac）

适合：**只有 Windows + 已有个人开发者账号（付费 $99 那种）**。

免费 Apple ID 的临时证书很难在 CI 稳定导出 IPA，本指南按 **付费个人/公司开发者** 编写。

---

## 总流程

```
① 苹果开发者后台 创建 App ID + 证书 + 描述文件
② Windows 上把 .p12 / .mobileprovision 转成 base64
③ 代码推到 GitHub，配置 Secrets
④ Actions 手动运行 → 下载 IPA
⑤ Sideloadly / 爱思 等签装到手机
```

---

## ① 苹果开发者后台准备

打开 [Apple Developer](https://developer.apple.com/account) → Certificates, Identifiers & Profiles。

### 1. 注册设备（Development / Ad Hoc 都需要）

- **Devices** → 登记你的 iPhone UDID  
- Windows 可在爱思助手 / 3uTools 查看 UDID  
- 或 Mac 上 Xcode → Window → Devices

### 2. 创建 App ID

- **Identifiers → App IDs → +**  
- Bundle ID 选 **Explicit**，例如：

```text
com.你的名字.n1photobackup
```

记住这个字符串，后面全程一致。

### 3. 创建证书

**Development IPA（自己手机调试安装）**

- Certificates → **Apple Development**  
- 若没有 CSR：可在另一台 Mac 用钥匙串生成；或用下面的 OpenSSL 在 Windows 生成（见附录）

**Ad Hoc IPA（装到登记过的多台设备）**

- Certificates → **Apple Distribution**

导出 **.p12**：

- 在生成证书的 Mac：**钥匙串访问** → 找到证书 → 右键「导出」→ `.p12`，设密码  
- 只有 Windows 时：用 OpenSSL 自己做 CSR/证书（附录），或临时借 Mac 导出一次

### 4. 创建描述文件 Provisioning Profile

- Profiles → +  
- 类型：
  - **iOS App Development**（对应 development 导出）
  - 或 **Ad Hoc**（对应 ad-hoc 导出）
- 勾选刚才的 App ID、证书、设备  
- 下载得到 `xxx.mobileprovision`  
- **名字**记下来（下载页显示的 Profile Name，或安装后 Xcode 里看到的名字），填到 Secret `PROVISIONING_PROFILE_NAME`

---

## ② Windows 上转 base64

在 PowerShell 里（改成你的真实路径）：

```powershell
# 证书 p12 → base64（单行）
[Convert]::ToBase64String([IO.File]::ReadAllBytes("D:\certs\n1_dev.p12")) | Set-Clipboard
# 已复制到剪贴板，粘贴到 GitHub Secret: APPLE_CERTIFICATE_BASE64

# 描述文件 → base64
[Convert]::ToBase64String([IO.File]::ReadAllBytes("D:\certs\N1PhotoBackup_Dev.mobileprovision")) | Set-Clipboard
# 粘贴到: APPLE_PROVISION_BASE64
```

也可用仓库脚本：

```powershell
cd C:\Users\Mrc\Documents\N1PhotoBackup
.\scripts\Encode-Secrets.ps1 -P12Path "D:\certs\n1_dev.p12" -ProfilePath "D:\certs\xxx.mobileprovision"
```

会在 `secrets-out\` 生成两个 `.txt`，内容整段复制到 GitHub。

---

## ③ 推到 GitHub 并配置 Secrets

### 初始化仓库（PowerShell）

```powershell
cd C:\Users\Mrc\Documents\N1PhotoBackup

# 若还没装 git：https://git-scm.com/download/win
git init
git add .
git commit -m "feat: N1 photo backup iOS app with CI IPA"

# 在 GitHub 网页新建空仓库后：
git remote add origin https://github.com/你的用户名/N1PhotoBackup.git
git branch -M main
git push -u origin main
```

### 配置 Secrets

仓库页 → **Settings → Secrets and variables → Actions → New repository secret**

| Name | 值 |
|------|-----|
| `APPLE_TEAM_ID` | 10 位，开发者账号 Membership 页可见 |
| `APPLE_CERTIFICATE_BASE64` | p12 的 base64 |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 p12 时设的密码 |
| `APPLE_PROVISION_BASE64` | mobileprovision 的 base64 |
| `PROVISIONING_PROFILE_NAME` | 描述文件名称（不是文件名） |
| `APPLE_BUNDLE_ID` | 与 App ID 完全一致，如 `com.xxx.n1photobackup` |
| `EXPORT_METHOD` | `development` 或 `ad-hoc`（可选，默认 development） |

**Team ID 在哪：**  
https://developer.apple.com/account → Membership details → Team ID  

**Profile 名称：**  
developer.apple.com → Profiles → 点开该 profile，顶部 **Name** 字段。

---

## ④ 运行 Actions 下载 IPA

1. GitHub 仓库 → **Actions**  
2. 左侧选 **Build IPA**  
3. **Run workflow**  
4. Export method 选 `development` 或 `ad-hoc`（需与描述文件类型匹配）  
5. 等 5–15 分钟，绿色勾 → 点进这次 run → **Artifacts → N1PhotoBackup-ipa** 下载  

解压 zip 得到 `N1PhotoBackup.ipa`。

---

## ⑤ 安装到 iPhone

任选其一（Windows）：

| 工具 | 说明 |
|------|------|
| [Sideloadly](https://sideloadly.io/) | 常用，填 Apple ID |
| 爱思助手 | 应用游戏 → 本地安装 ipa |
| AltStore / SideStore | 需电脑保活或自签刷新 |
| Apple Configurator | 需 Mac |

**Development / Ad Hoc** 只能装到描述文件里登记过的 UDID。  
换新手机要先加 UDID → 更新 Profile → 重新跑 Actions。

---

## 常见失败

| 日志关键词 | 原因 | 处理 |
|-----------|------|------|
| `No signing certificate` | p12 不对或密码错 | 重导证书，确认含私钥 |
| `No profiles for` | Bundle ID 与 Profile 不一致 | 三处统一：Secret / App ID / project |
| `requires a development team` | Team ID 错 | 检查 APPLE_TEAM_ID |
| `Provisioning profile doesn't include device` | 没登记 UDID | 设备加入 Profile 后重新下载并更新 Secret |
| `Export method` 不匹配 | development 证书配了 ad-hoc 导出 | 方法与证书/Profile 类型一致 |
| Archive 编译错误 | 源码问题 | 看 Actions 日志 xcodebuild 段 |

---

## 安全注意

- **不要**把 p12、描述文件、base64 提交进 git  
- `secrets-out/` 已在 `.gitignore`  
- 证书泄露可在开发者后台 **Revoke** 后重签  

---

## 附录：仅 Windows 用 OpenSSL 生成 CSR（可选）

若完全没有 Mac 做 CSR：

```powershell
# 需安装 OpenSSL（或 Git for Windows 自带）
openssl genrsa -out ios_dev.key 2048
openssl req -new -key ios_dev.key -out ios_dev.csr -subj "/emailAddress=你@邮箱.com/CN=N1 Dev/C=CN"
```

把 `ios_dev.csr` 上传到苹果后台创建证书，下载 `.cer` 后：

```powershell
openssl x509 -in development.cer -inform DER -out development.pem -outform PEM
openssl pkcs12 -export -inkey ios_dev.key -in development.pem -out n1_dev.p12 -password pass:你的密码
```

再用前面的 base64 步骤。

---

## 和本仓库的对应关系

| 文件 | 作用 |
|------|------|
| `project.yml` | XcodeGen 生成 `.xcodeproj` |
| `.github/workflows/build-ipa.yml` | CI 打包流程 |
| `ExportOptions-*.plist` | 导出 IPA 参数模板 |
| `scripts/Encode-Secrets.ps1` | Windows 一键 base64 |
| `docs/GITHUB_ACTIONS_IPA.md` | 本文 |
