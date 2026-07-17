# N1 Photo Backup

把 iPhone 相册备份到 **N1（iStoreOS + USB）** 的 iOS App。

## 协议

**仅 SFTP**（SSH 文件传输）。依赖 **Citadel**（静态库，链进主二进制），重签安装友好。

| 字段 | 示例 |
|------|------|
| 主机 | `192.168.1.10` |
| 端口 | `22` |
| 用户 / 密码 | SSH 账号 |
| 或私钥 | OpenSSH 格式 ed25519/RSA |
| 基础路径 | `/mnt/sda1/PhoneBackup` |

- 可保存多台 SFTP 服务器，备份前切换当前目标  
- 密码 / 私钥存 **Keychain**  
- 按 `年/月` 建目录，已存在文件可跳过  
- **多连接并发上传**（设置里调 1–8 路，默认 4；每路独立 SFTP 会话）  
- **备份时保持屏幕常亮**（可关；仅上传进行中生效）  

## 使用

1. **设置 → SFTP 服务器 → +**
2. 填写主机、端口、账号、基础路径  
3. **测试连接 → 保存**，并点选为当前目标  
4. 「备份」页：选图 / 最近 N 天 / 全部  

## 未签名 IPA（牛蛙助手）

见 [START_CI.md](./START_CI.md) 或 [docs/UNSIGNED_IPA_NIUWA.md](./docs/UNSIGNED_IPA_NIUWA.md)：

1. `git push` 到 GitHub  
2. Actions → **Build Unsigned IPA**  
3. 下载 `N1PhotoBackup-unsigned.ipa`  
4. 牛蛙助手签名安装  

最低 **iOS 17**。

## N1 端

```sh
mkdir -p /mnt/sda1/PhoneBackup
# 确保 SSH 开启，用户对该目录可写
```

## 项目结构

```text
N1PhotoBackup/
├── Models/          # 服务器配置
├── Services/        # SFTPClient + 相册/上传
└── Views/
```

## 连接失败排查

若测试连接出现 `NIOSSH.NIOSSHError 错误 1`：

1. 确认已安装 **v1.5.1+**（兼容 Dropbear 算法）；**v1.6.0+** 起支持多连接并发与屏幕常亮
2. 手机与 N1 同一 Wi‑Fi，FinalShell / 系统 SSH 能用相同账号密码登录
3. 主机填 **局域网 IP**（如 `192.168.1.10`），端口 **22**
4. N1 上先 `mkdir -p /mnt/sda1/PhoneBackup` 并保证该用户可写

## License

MIT
