# 未签名 IPA + 牛蛙助手安装

**淘宝个人证书 + 牛蛙助手**。不需要把证书上传到 GitHub。

本版 **仅 SFTP**，依赖 Citadel **静态库**，IPA 里没有第三方 `.framework`，重签后应能正常安装。

## 3 步

### ① 推送代码

```powershell
cd C:\Users\synapsor\Desktop\dev\n1backup
git push origin master:main
```

### ② Actions 下载包

1. 仓库 → **Actions** → **Build Unsigned IPA** → **Run workflow**  
2. 绿勾 → **Artifacts → N1PhotoBackup-unsigned-ipa**  
3. 解压得到 `N1PhotoBackup-unsigned.ipa`（版本 ≥ **1.5.0**）

### ③ 牛蛙签名安装

1. 导入证书  
2. 导入 ipa  
3. 签名 → 安装（建议先删手机上旧版）  
4. 设备 **iOS 17+**

## 使用

设置 → SFTP 服务器 → 主机 / 22 / 用户密码 → 基础路径如 `/mnt/sda1/PhoneBackup` → 测试 → 保存 → 备份。
