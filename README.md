# N1 Photo Backup

把 iPhone 相册备份到 **N1（iStoreOS + USB）** 的 iOS App。

## 协议

支持 **SFTP** 与 **WebDAV**。

| 协议 | 依赖 | 说明 |
|------|------|------|
| **SFTP** | Citadel（静态库） | SSH 文件传输，OpenSSH / Dropbear |
| **WebDAV** | 系统 URLSession | AList / Nextcloud / 通用 WebDAV；局域网常更省 CPU、并发更稳 |

| 字段 | SFTP 示例 | WebDAV 示例 |
|------|-----------|-------------|
| 主机 | `192.168.1.10` | `192.168.1.10` |
| 端口 | `22` | `5244`（AList 常见） |
| 用户 / 密码 | SSH 账号 | WebDAV 账号 |
| 或私钥 | OpenSSH ed25519/RSA | — |
| HTTPS / 自签 | — | 可选；内网可忽略证书 |
| 基础路径 | `/mnt/sda1/PhoneBackup` | `/dav/本地存储/PhoneBackup` |

- 可保存多台服务器，备份前切换当前目标  
- 密码 / 私钥存 **Keychain**  
- 按 `年/月` 建目录，已存在文件可跳过  
- **多连接并发上传**（1–6 路，默认 3；持续工作池）  
- **备份时保持屏幕常亮**（可关）  
- **上传速度显示**（张/秒，近 8 秒滑动窗口）  

## 使用

1. **设置 → 备份服务器 → +**（SFTP 或 WebDAV）  
2. 填写主机、端口、账号、基础路径 → **测试连接 → 保存**  
3. 点选为当前目标  
4. 「备份」页：选图 / 最近 N 天 / 全部  

## 未签名 IPA（牛蛙助手）

见 [START_CI.md](./START_CI.md) 或 [docs/UNSIGNED_IPA_NIUWA.md](./docs/UNSIGNED_IPA_NIUWA.md)：

1. `git push` 到 GitHub  
2. Actions → **Build Unsigned IPA**  
3. 下载 `N1PhotoBackup-unsigned.ipa`  
4. 牛蛙助手签名安装  

最低 **iOS 17**。

## N1 端

### SFTP

```sh
mkdir -p /mnt/sda1/PhoneBackup
# 确保 SSH 开启，用户对该目录可写
```

### WebDAV（AList 示例）

1. 安装 AList，把 USB 目录加为存储  
2. 开启 WebDAV，记下端口（常见 5244）与路径  
3. App 里协议选 WebDAV，基础路径如 `/dav/本地存储/PhoneBackup`  

## 项目结构

```text
N1PhotoBackup/
├── Models/          # 服务器配置
├── Services/        # SFTP / WebDAV + 相册/上传
└── Views/
```

## 连接失败排查

### SFTP · `NIOSSH.NIOSSHError` / `NIOCore.IOError 错误 1`

1. 确认 **v1.5.1+** 兼容算法；**v1.6.1+** 分块写与断线重试；**v1.7.0+** 支持 WebDAV  
2. 并发过高易断：设置里降到 **2**  
3. 手机与 N1 同一 Wi‑Fi，FinalShell 能登录  
4. 主机填局域网 IP，端口 22  

### WebDAV

1. 浏览器或电脑先测 `http://IP:端口/路径`  
2. 确认用户可写、基础路径正确（含 `/dav/...`）  
3. HTTPS 自签时勾选「忽略证书校验」  
4. **HTTP 404**：路径不存在。v1.7.1+ 测试连接会尝试自动 `MKCOL` 建目录；仍失败则检查 AList 存储名与 `/dav` 前缀  
5. **HTTP 405**：方法不被允许。常见原因是主机/端口指到了非 WebDAV 端点，或路径少了 `/dav`；主机只填 IP，不要带 `http://`  
6. AList：设置 → WebDAV，端口默认 5244，路径形如 `/dav/本地存储/PhoneBackup`  

## License

MIT
