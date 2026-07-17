# 立刻开干：打未签名 IPA → 牛蛙助手安装

**SFTP only · v1.5+**（静态 Citadel，无动态 framework）

## 三步走

### 1. 推送到 GitHub

```powershell
cd C:\Users\synapsor\Desktop\dev\n1backup
git push origin master:main
```

### 2. Actions 下载未签名 IPA

仓库 → **Actions** → **Build Unsigned IPA** → **Run workflow**  
→ 绿勾 → **Artifacts → N1PhotoBackup-unsigned-ipa**  
→ 解压得到 `N1PhotoBackup-unsigned.ipa`

### 3. 牛蛙助手

导入证书 → 导入 ipa → 签名 → 安装。  
设备 **iOS 17+**。删掉手机上旧版再装更稳。

## 若安装失败

1. 确认是 **最新** Actions 产物（版本 ≥ 1.5.0）  
2. 证书 UDID / 有效期正常  
3. 先卸载旧 App 再装  
