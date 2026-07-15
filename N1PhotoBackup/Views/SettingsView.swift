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
                            Image(systemName: "server.rack")
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("存储服务器")
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
                    Text("支持 WebDAV / SMB / SFTP / FTP。新建时选择协议并填写对应授权信息。")
                }

                Section("上传选项") {
                    Toggle("跳过远端已存在的文件", isOn: $uploadManager.skipExisting)
                }

                Section("N1 / iStoreOS") {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("USB 在 DiskMan 挂载后，用 Samba / Alist / SSH / FTP 任一暴露")
                        tip("WebDAV：Docker Alist 或 bytemark/webdav")
                        tip("SMB：Luci 开启 Samba，填共享名即可（已内置）")
                        tip("SFTP：系统 SSH，填用户密码与 /mnt/... 路径即可（已内置）")
                    }
                    .padding(.vertical, 4)
                }

                Section("关于") {
                    LabeledContent("应用", value: "N1 相册备份")
                    LabeledContent("协议", value: "WebDAV · SMB · SFTP · FTP")
                    LabeledContent("版本", value: "1.1")
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
