import SwiftUI

struct ServerEditView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State var server: StorageServer
    @State var credentials: ServerCredentials
    let isNew: Bool

    @State private var showPassword = false
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var showDeleteConfirm = false

    private var fields: Set<ServerFormField> {
        server.protocolKind.formFields
    }

    var body: some View {
        Form {
            protocolSection
            identitySection
            connectionSection
            authSection
            pathSection
            optionsSection
            actionSection
            helpSection
        }
        .navigationTitle(isNew ? "新建连接" : "编辑连接")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save(andDismiss: true) }
                    .fontWeight(.semibold)
            }
        }
        .onChange(of: server.protocolKind) { _, newKind in
            // 切换协议时给合理默认端口 / 路径
            server.port = newKind.defaultPort
            if server.basePath.isEmpty || server.basePath == "/PhoneBackup" || server.basePath == "PhoneBackup" {
                server.basePath = newKind == .smb ? "PhoneBackup" : "/PhoneBackup"
            }
        }
        .confirmationDialog("删除此服务器？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                serverStore.delete(id: server.id)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var protocolSection: some View {
        Section {
            Picker("协议", selection: $server.protocolKind) {
                ForEach(StorageProtocolKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind)
                }
            }
            .disabled(!isNew) // 编辑时避免误改协议导致字段混乱；需要可再放开

            if !isNew {
                Text("如需换协议，请新建一条连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("协议类型")
        } footer: {
            Text(server.protocolKind.subtitle)
        }
    }

    private var identitySection: some View {
        Section("显示名称") {
            TextField("例如：家里 N1 / 备份盘", text: $server.name)
        }
    }

    private var connectionSection: some View {
        Section("连接") {
            if fields.contains(.host) {
                TextField("主机 IP / 域名", text: $server.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            if fields.contains(.port) {
                HStack {
                    Text("端口")
                    Spacer()
                    TextField("端口", value: $server.port, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
            }
            if fields.contains(.useTLS) {
                Toggle(server.protocolKind == .ftp ? "使用 FTPS (TLS)" : "使用 HTTPS", isOn: $server.useTLS)
            }
            if fields.contains(.allowInsecureTLS) {
                Toggle("忽略证书校验（内网自签）", isOn: $server.allowInsecureTLS)
                    .disabled(!server.useTLS)
            }
            if fields.contains(.shareName) {
                TextField("共享名（Share）", text: $server.shareName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if fields.contains(.domain) {
                TextField("域名 / Domain（可选）", text: $server.domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if fields.contains(.workgroup) {
                TextField("工作组 Workgroup（可选）", text: $server.workgroup)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if fields.contains(.ftpPassive) {
                Toggle("被动模式 PASV（推荐）", isOn: $server.ftpPassive)
            }
        }
    }

    private var authSection: some View {
        Section {
            if fields.contains(.username) {
                TextField("用户名", text: $server.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if fields.contains(.password) {
                HStack {
                    Group {
                        if showPassword {
                            TextField("密码", text: $credentials.password)
                        } else {
                            SecureField("密码", text: $credentials.password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if fields.contains(.privateKey) {
                Toggle("使用 SSH 私钥", isOn: $server.usePrivateKey)
                if server.usePrivateKey {
                    Text("私钥 PEM / OpenSSH 正文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $credentials.privateKey)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                    SecureField("私钥口令（可选）", text: $credentials.passphrase)
                        .textInputAutocapitalization(.never)
                }
            }
        } header: {
            Text("授权信息")
        } footer: {
            Text("密码与私钥保存在系统钥匙串，不会明文写入配置文件。")
        }
    }

    private var pathSection: some View {
        Section {
            if fields.contains(.basePath) {
                TextField(
                    server.protocolKind == .smb ? "共享内路径（可空）" : "基础路径",
                    text: $server.basePath
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            if fields.contains(.folderLayout) {
                Picker("目录结构", selection: $server.folderLayout) {
                    ForEach(StorageServer.FolderLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
            }
        } header: {
            Text("备份路径")
        } footer: {
            pathFooter
        }
    }

    private var pathFooter: Text {
        switch server.protocolKind {
        case .webdav:
            return Text("Alist 示例：基础路径 /dav/本地/PhoneBackup ；通用 WebDAV 多为 /PhoneBackup")
        case .smb:
            return Text("共享名填 Samba 里的 share（如 sda1）。共享内路径可填 PhoneBackup，最终为 \\\\host\\share\\PhoneBackup\\年\\月\\")
        case .sftp:
            return Text("基础路径为 SSH 用户可见的绝对路径，如 /mnt/sda1/PhoneBackup")
        case .ftp:
            return Text("基础路径相对于 FTP 登录根目录，如 /PhoneBackup")
        }
    }

    private var optionsSection: some View {
        Section("依赖说明") {
            switch server.protocolKind {
            case .webdav, .ftp:
                Label("系统自带 URLSession，无需额外库", systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .smb:
                Text(SMBStorageClient.dependencyHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .sftp:
                Text(SFTPStorageClient.dependencyHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Spacer()
                    if isTesting {
                        ProgressView()
                    } else {
                        Text("测试连接")
                    }
                    Spacer()
                }
            }
            .disabled(isTesting || server.host.isEmpty)

            if let testMessage {
                Text(testMessage)
                    .font(.footnote)
                    .foregroundStyle(testOK ? .green : .red)
            }

            if !isNew {
                Button("删除此服务器", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
    }

    private var helpSection: some View {
        Section("字段速查 · \(server.protocolKind.title)") {
            ForEach(helpLines, id: \.self) { line in
                Text("• \(line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var helpLines: [String] {
        switch server.protocolKind {
        case .webdav:
            return [
                "主机：N1 局域网 IP",
                "端口：Alist 默认 5244，bytemark/webdav 常用 8080",
                "用户名/密码：WebDAV 服务账号",
                "基础路径：必须是 WebDAV 可写目录"
            ]
        case .smb:
            return [
                "主机：N1 IP，端口一般 445",
                "共享名：Luci Samba 里配置的共享名称",
                "用户名/密码：Samba 用户（或 guest 空密码）",
                "需添加 AMSMB2 Swift 包"
            ]
        case .sftp:
            return [
                "主机：N1 IP，端口 22（或你改过的 SSH 端口）",
                "用户名/密码：系统 SSH 用户",
                "或粘贴私钥（openssh/pem）",
                "基础路径：USB 挂载点，如 /mnt/sda1/PhoneBackup",
                "需添加 Citadel Swift 包"
            ]
        case .ftp:
            return [
                "主机 + 端口（默认 21）",
                "建议被动模式；FTPS 打开 TLS",
                "部分路由器 FTP 实现有兼容性差异，优先 WebDAV/SFTP"
            ]
        }
    }

    // MARK: - Actions

    private func save(andDismiss: Bool) {
        server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.basePath = server.basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        server.shareName = server.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        serverStore.upsert(server, credentials: credentials)
        if andDismiss { dismiss() }
    }

    private func test() async {
        save(andDismiss: false)
        isTesting = true
        testMessage = nil
        testOK = false
        defer { isTesting = false }

        do {
            let client = try StorageClientFactory.make(server: server, credentials: credentials)
            try await client.testConnection()
            testOK = true
            testMessage = "连接成功 ✓  可以设为备份目标并开始上传"
        } catch {
            testOK = false
            testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
