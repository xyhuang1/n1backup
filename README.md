# N1 Photo Backup

把 iPhone 相册备份到 **N1（iStoreOS + USB 硬盘）** 或任意兼容存储的 iOS App。

## 多协议 · 多服务器

新建连接时**自选协议**，并填写该协议需要的授权信息：

| 协议 | 典型场景 | 授权字段 | 依赖 |
|------|----------|----------|------|
| **WebDAV** | Alist / Nextcloud / docker webdav | 主机、端口、HTTPS、用户、密码、基础路径 | 系统自带 |
| **SMB / Samba** | iStoreOS Samba 共享 | 主机、端口、共享名、用户、密码、域/工作组、共享内路径 | [AMSMB2](https://github.com/amosavian/AMSMB2) |
| **SFTP** | OpenSSH / dropbear | 主机、端口、用户、密码或私钥、基础路径 | [Citadel](https://github.com/orlandos-nl/Citadel) |
| **FTP / FTPS** | vsftpd 等 | 主机、端口、TLS、用户、密码、路径、被动模式 | 系统自带 |

- 可保存**多台**服务器，备份前切换「当前目标」
- 密码 / 私钥存 **Keychain**
- 按 `年/月` 建目录，已存在文件可跳过

---

## 使用流程（App 内）

1. **设置 → 存储服务器 → +**
2. 选择协议（WebDAV / SMB / SFTP / FTP）
3. 填写显示名、主机、端口、账号密码（及协议特有字段）
4. 点 **测试连接** → **保存**
5. 列表中点选为当前目标（绿色 ✓）
6. 回到「备份」页：选图 / 最近 N 天 / 全部

### 各协议填写示例（N1）

#### WebDAV（推荐，零依赖）

```
显示名: 家里N1-WebDAV
主机: 192.168.1.10
端口: 8080          # 或 Alist 5244
HTTPS: 关
用户 / 密码: 你的 WebDAV 账号
基础路径: /         # Alist 常为 /dav/本地存储名/PhoneBackup
```

#### SMB

```
显示名: 家里N1-Samba
主机: 192.168.1.10
端口: 445
共享名: sda1        # Luci Samba 里的共享名
用户 / 密码: samba 用户
共享内路径: PhoneBackup
域名 / 工作组: 可空 / WORKGROUP
```

#### SFTP

```
显示名: 家里N1-SFTP
主机: 192.168.1.10
端口: 22
用户 / 密码: root 或普通用户
# 或打开「使用 SSH 私钥」粘贴私钥
基础路径: /mnt/sda1/PhoneBackup
```

#### FTP

```
显示名: 家里N1-FTP
主机: 192.168.1.10
端口: 21
用户 / 密码: ftp 用户
基础路径: /PhoneBackup
被动模式: 开
```

---

## 没有 Mac？打未签名 IPA（牛蛙助手 / 淘宝证书）

**推荐你这种用法** → 看 **[START_CI.md](./START_CI.md)** 或 **[docs/UNSIGNED_IPA_NIUWA.md](./docs/UNSIGNED_IPA_NIUWA.md)**：

1. 源码 `git push` 到 GitHub  
2. Actions 运行 **Build Unsigned IPA**（**不用**上传证书）  
3. 下载 `N1PhotoBackup-unsigned.ipa`  
4. 用 **牛蛙助手** 导入你的证书签名安装  

> 无法在对话里直接附带编好的 ipa：Windows 编不了 iOS，必须云端/Mac 编译一次。

正规开发者账号、要 CI 直接签好的包：见 [docs/GITHUB_ACTIONS_IPA.md](./docs/GITHUB_ACTIONS_IPA.md)。

## Xcode 工程（有 Mac 时）

详见 [XCODE_SETUP.md](./XCODE_SETUP.md)。最低 **iOS 17**。  
也可用 `brew install xcodegen && xcodegen generate` 直接生成 `.xcodeproj`。

### 可选 Swift 包（SMB / SFTP）

**File → Add Package Dependencies…**

| 协议 | URL |
|------|-----|
| SMB | `https://github.com/amosavian/AMSMB2` |
| SFTP | `https://github.com/orlandos-nl/Citadel` |

未添加时，选对应协议点「测试连接」会提示需要依赖；WebDAV / FTP 不受影响。

### Info 权限

- 相册：`NSPhotoLibraryUsageDescription`
- 本地网络：`NSLocalNetworkUsageDescription`
- ATS：允许本地 HTTP（内网 WebDAV/FTP）

---

## N1 端

- USB 挂载后建目录：`mkdir -p /mnt/sda1/PhoneBackup`
- WebDAV 快速启动见 [docker-webdav-compose.yml](./docker-webdav-compose.yml)
- Samba：`luci-app-samba4` 共享 USB 路径
- SFTP：系统 SSH，确保用户对 USB 目录可写

---

## 项目结构

```text
N1PhotoBackup/
├── Models/
│   ├── StorageProtocolKind.swift   # 协议枚举 + 表单字段
│   ├── StorageServer.swift         # 单条连接配置
│   └── ServerStore.swift           # 多服务器仓库
├── Services/
│   ├── StorageClient.swift         # 统一接口 + 工厂
│   ├── WebDAVClient.swift
│   ├── SMBClient.swift
│   ├── SFTPClient.swift
│   ├── FTPClient.swift
│   ├── PhotoLibraryService.swift
│   ├── UploadManager.swift
│   └── KeychainStore.swift
└── Views/
    ├── ServerListView.swift        # 服务器列表
    ├── ServerEditView.swift        # 新建/编辑（按协议动态表单）
    ├── HomeView.swift
    ├── UploadQueueView.swift
    └── SettingsView.swift
```

---

## 安全

- 仅建议家庭局域网使用
- 勿把 SMB/WebDAV/FTP 端口映射公网
- 「忽略证书」仅用于可信内网自签

## License

MIT
