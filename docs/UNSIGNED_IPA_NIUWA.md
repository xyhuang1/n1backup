# 未签名 IPA + 牛蛙助手安装

你的情况：**淘宝个人证书 + 牛蛙助手签名**。  
不需要把证书上传到 GitHub，只要拿到 **未签名 IPA**，本地用牛蛙重签即可。

> 我无法在对话里直接塞给你一个编好的 `.ipa` 文件：  
> 当前是 Windows 环境，没有苹果编译器，必须经过 **GitHub 云端 Mac**（或真 Mac）编译一次。

---

## 你只要做这 3 步

### ① 把代码推到 GitHub（只需一次）

在 PowerShell：

```powershell
cd C:\Users\Mrc\Documents\N1PhotoBackup

git init
git add .
git commit -m "feat: N1 photo backup unsigned IPA CI"

# 浏览器打开 github.com → New repository（不要勾选 README）
# 假设仓库名 N1PhotoBackup：
git remote add origin https://github.com/你的用户名/N1PhotoBackup.git
git branch -M main
git push -u origin main
```

若提示登录，用 GitHub 网页生成的 Personal Access Token 当密码。

### ② 跑 Actions 下载未签名包

1. 打开你的仓库页  
2. 顶部 **Actions**  
3. 左侧点 **Build Unsigned IPA**  
4. 右侧 **Run workflow** → **Run workflow**  
5. 等几分钟出现绿色 ✓  
6. 点进这次运行 → 底部 **Artifacts**  
7. 下载 **N1PhotoBackup-unsigned-ipa**  
8. 解压 zip，得到：

   - `N1PhotoBackup-unsigned.ipa` ← 给牛蛙用  
   - `N1PhotoBackup.app.zip`（备用）

**不需要**配置任何证书 Secrets。

### ③ 牛蛙助手签名安装

1. 打开牛蛙助手，导入你的淘宝证书（按软件说明）  
2. 导入 `N1PhotoBackup-unsigned.ipa`  
3. 如需修改 Bundle ID，在软件里改（避免和别的包冲突）  
4. 签名 → 安装到手机  

不同版本文案可能是「添加应用 / 导入 IPA / 一键签名」，流程相同。

---

## 为什么不能「直接发你一个 ipa」

| 原因 | 说明 |
|------|------|
| 未编译 | 现在仓库里只有源码，没有 arm64 机器码 |
| Windows 编不了 iOS | 必须 Xcode（Mac 或 GitHub macos runner） |
| 对话传文件限制 | 即使编好，也要通过 Actions Artifact / 网盘交付 |

GitHub Actions 编一次 ≈ 你在云端借了一台 Mac 点编译，编完你下载即可。

---

## 和「自带证书 CI」的区别

| | 未签名 IPA（本流程） | 签名 IPA |
|--|---------------------|----------|
| 证书上传 GitHub | **不需要** | 需要 |
| 谁签名 | 你用牛蛙本地签 | CI 用 p12 签 |
| 适合 | 淘宝证书 + 牛蛙 | 正规开发者后台描述文件 |

你这种淘宝证书场景，**用未签名流程更合适**。

---

## 常见问题

**Q: Actions 是灰色的 / 没有 Run workflow？**  
A: 先成功 `git push`；Actions 可能要先在仓库 Settings 里启用。首次 push 到 main 也会自动触发一次。

**Q: 构建失败？**  
A: 点进红色 run，打开 `build.log`，把错误贴出来我帮你看。

**Q: 牛蛙提示包损坏？**  
A: 确认下的是 `N1PhotoBackup-unsigned.ipa`，不要只下了外层 GitHub artifact 的 zip 却没解压；或改用 `N1PhotoBackup.app.zip` 再压成 ipa。

**Q: 装上闪退？**  
A: 证书描述文件是否包含该机 UDID；或插件未打开「开发者模式」；设置 → 通用 → VPN 与设备管理 里信任企业/描述文件。

**Q: 不想公开源码？**  
A: 建 **Private** 仓库即可，Actions 对私有库按账号套餐计时（一般个人够用）。

---

## 装好 App 之后

1. 打开 **N1相册备份**  
2. 设置 → 添加 WebDAV/SMB 等  
3. 填 N1 地址测试连接 → 备份  

N1 WebDAV 可参考仓库根目录 `docker-webdav-compose.yml`。
