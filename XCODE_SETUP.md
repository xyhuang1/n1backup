# 在 Mac 上用 Xcode 打开本项目

## 推荐：XcodeGen

```bash
brew install xcodegen
cd /path/to/n1backup
xcodegen generate
open N1PhotoBackup.xcodeproj
```

会自动拉取 **Citadel**（SFTP，静态链接）。最低 **iOS 17**。

## 首次运行

- [ ] 设置 → SFTP：主机 / 端口 22 / 用户密码 / 基础路径  
- [ ] N1 上 SSH 开启，`mkdir -p /mnt/sda1/PhoneBackup`  
- [ ] 手机与 N1 同一局域网  
- [ ] 「测试连接」成功  
- [ ] 上传 1 张测试照片  

## 常见问题

| 现象 | 处理 |
|------|------|
| 部署版本错误 | iOS 17+ |
| 相册权限无弹窗 | Info 中 Photo Library Usage Description |
| Signing 失败 | 换 Bundle ID，登录 Apple ID |
| 重签后装不上 | 用 Actions 最新 1.5+ 未签名 IPA（无动态 framework） |
