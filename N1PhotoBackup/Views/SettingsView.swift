import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var uploadManager: UploadManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ServerListView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("SFTP 服务器")
                                    .font(.body.weight(.semibold))
                                if let s = serverStore.selectedServer {
                                    Text("当前：\(s.displayTitle)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(s.summaryLine)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                } else {
                                    Text("尚未配置，点此添加")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("连接")
                } footer: {
                    Text("本版本仅支持 SFTP（SSH）。在 N1 上开启 SSH，填 IP、用户、密码与备份目录即可。")
                }

                Section {
                    Toggle("跳过远端已存在的文件", isOn: $uploadManager.skipExisting)
                    Toggle("备份时保持屏幕常亮", isOn: $uploadManager.keepScreenOn)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("并发上传")
                            Spacer()
                            Text("\(uploadManager.maxConcurrentUploads) 路")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(uploadManager.maxConcurrentUploads) },
                                set: { uploadManager.maxConcurrentUploads = Int($0.rounded()) }
                            ),
                            in: Double(UploadManager.minConcurrency)...Double(UploadManager.maxConcurrency),
                            step: 1
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("上传选项")
                } footer: {
                    Text("每路使用独立 SFTP 连接。路数越高速度通常越快，但更占带宽与 N1 CPU；Wi‑Fi 较弱时可降到 2。常亮仅在上传进行中生效。")
                }

                Section("N1 / iStoreOS") {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("USB 挂载后：mkdir -p /mnt/sda1/PhoneBackup")
                        tip("系统 SSH 保持开启；手机与 N1 同一 Wi‑Fi")
                        tip("确认登录用户对该目录有写权限")
                    }
                    .padding(.vertical, 4)
                }

                Section("关于") {
                    LabeledContent("应用", value: "N1 相册备份")
                    LabeledContent("协议", value: "SFTP only")
                    LabeledContent("版本", value: "1.6.0")
                }
            }
            .navigationTitle("设置")
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
