# 立刻开干：打未签名 IPA → 牛蛙助手安装

适合：**淘宝/第三方个人证书 + 牛蛙助手（或同类超级签名）**。

**不需要**把证书传到 GitHub。  
**需要**推一次代码，让 GitHub 云端 Mac 编译出未签名包。

更细说明：`docs/UNSIGNED_IPA_NIUWA.md`

---

## 三步走

### 1. 推送到 GitHub

```powershell
cd C:\Users\Mrc\Documents\N1PhotoBackup
git init
git add .
git commit -m "feat: N1 photo backup"
# 网页新建仓库后：
git remote add origin https://github.com/你的用户名/N1PhotoBackup.git
git branch -M main
git push -u origin main
```

### 2. Actions 下载未签名 IPA

仓库 → **Actions** → **Build Unsigned IPA** → **Run workflow**  
→ 绿勾 → **Artifacts → N1PhotoBackup-unsigned-ipa**  
→ 解压得到 `N1PhotoBackup-unsigned.ipa`

### 3. 牛蛙助手

导入证书 → 导入上述 ipa → 签名 → 安装手机。

---

## 说明

我无法在这个对话里直接生成/发送编好的 `.ipa`：  
当前是 Windows，没有 iOS 编译器。  
「Build Unsigned IPA」就是帮你在云端免费编一次，产物你自己下。

若你坚持用「证书进 CI 直接签好」，见 `docs/GITHUB_ACTIONS_IPA.md`（一般淘宝证书 + 牛蛙不需要那条路）。
