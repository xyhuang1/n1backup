# 在 Mac 上用 Xcode 打开本项目

本仓库只有 Swift 源码（在 Windows 上生成），需要在 Mac 上创建 Xcode App 工程并导入。

## 方法一：手动新建（推荐，5 分钟）

1. 将整个 `N1PhotoBackup` 文件夹拷到 Mac（U 盘 / 网盘 / `scp` 均可）
2. 打开 **Xcode 15+**
3. **File → New → Project → iOS → App**
   - Product Name: `N1PhotoBackup`
   - Team: 选择你的 Apple ID
   - Organization Identifier: 例如 `com.yourname`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: None
4. 保存位置任选（不要直接盖住本仓库的源码目录也可）
5. 删除 Xcode 自动生成的：
   - `ContentView.swift`
   - `N1PhotoBackupApp.swift`
6. 把本仓库 `N1PhotoBackup/N1PhotoBackup/` 下所有子目录和 `.swift` 文件
   **拖进 Xcode 工程导航器**（勾选 *Copy items if needed*、*Create groups*、Target 勾选 `N1PhotoBackup`）
7. 将本仓库根目录 `Info.plist` 的键值合并进 Target → **Info**：
   - `NSPhotoLibraryUsageDescription`
   - `NSLocalNetworkUsageDescription`
   - `NSAppTransportSecurity` → `NSAllowsArbitraryLoads` = YES  
     `NSAllowsLocalNetworking` = YES
8. **General → Minimum Deployments** 设为 **iOS 17.0**
9. 连接 iPhone，选真机，点 Run

> 免费 Apple ID 可真机调试 7 天需重签；上架 App Store 需付费开发者账号。自用备份选「Development」即可。

## 方法二：命令行（有 Xcode 时）

```bash
# 假设源码在 ~/N1PhotoBackup
cd ~/N1PhotoBackup

# 用 Xcode 模板生成工程后，把源码拖进去（见方法一）
# 或安装 xcodegen 后自行写 project.yml
```

## 首次运行检查清单

- [ ] 设置页能保存主机 IP / 端口 / 账号
- [ ] N1 上 WebDAV 已启动（见 README + docker-webdav-compose.yml）
- [ ] 手机与 N1 同一局域网
- [ ] 「测试连接」显示成功
- [ ] 系统弹窗允许相册 + 本地网络
- [ ] 上传 1 张测试照片，在 N1 的 `PhoneBackup/年/月/` 下能看到文件

## 常见编译问题

| 现象 | 处理 |
|------|------|
| `ContentUnavailableView` 找不到 | 部署版本改为 iOS 17+ |
| 相册权限无弹窗 | 检查 Info 里是否有 Photo Library Usage Description |
| 明文 HTTP 被拦 | ATS Allow Arbitrary Loads / Local Networking |
| Signing 失败 | 换自己的 Bundle ID，登录 Apple ID |
