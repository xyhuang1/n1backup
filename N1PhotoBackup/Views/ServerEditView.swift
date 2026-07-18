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
            server.port = newKind.defaultPort
            let defaults = Set(StorageProtocolKind.allCases.map(\.defaultBasePath))
            if server.basePath.isEmpty || defaults.contains(server.basePath)
                || server.basePath == "/PhoneBackup" || server.basePath == "PhoneBackup" {
                server.basePath = newKind.defaultBasePath
            }
            if newKind != .sftp {
                server.usePrivateKey = false
            }
            if newKind != .webdav {
                server.useTLS = false
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
            .disabled(!isNew)

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
            TextField("例如：家里 N1", text: $server.name)
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("主机 IP / 域名", text: $server.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            HStack {
                Text("端口")
                Spacer()
                TextField("端口", value: $server.port, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
            if fields.contains(.useTLS) {
                Toggle("使用 HTTPS", isOn: $server.useTLS)
            }
            if fields.contains(.allowInsecureTLS) {
                Toggle("忽略证书校验（内网自签）", isOn: $server.allowInsecureTLS)
                    .disabled(!server.useTLS)
            }
        } header: {
            Text("连接")
        } footer: {
            switch server.protocolKind {
            case .sftp:
                Text("N1 / iStoreOS 一般开启系统 SSH，端口 22。")
            case .webdav:
                Text("AList 默认 5244；其它 WebDAV 常见 80/8080/5005。局域网可关 HTTPS。")
            }
        }
    }

    private var authSection: some View {
        Section {
            TextField("用户名", text: $server.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
                Button { showPassword.toggle() } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
            if fields.contains(.privateKey) {
                Toggle("使用 SSH 私钥", isOn: $server.usePrivateKey)
                if server.usePrivateKey {
                    Text("OpenSSH 私钥正文（ed25519 / RSA）")
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
            Text("授权")
        } footer: {
            if server.protocolKind == .sftp {
                Text("密码与私钥保存在系统钥匙串。推荐密码登录；私钥需 OpenSSH 格式。")
            } else {
                Text("WebDAV Basic 认证；密码保存在系统钥匙串。")
            }
        }
    }

    private var pathSection: some View {
        Section {
            TextField("基础路径", text: $server.basePath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("目录结构", selection: $server.folderLayout) {
                ForEach(StorageServer.FolderLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
        } header: {
            Text("备份路径")
        } footer: {
            switch server.protocolKind {
            case .sftp:
                Text("SSH 用户可见的绝对路径，如 /mnt/sda1/PhoneBackup。请先 mkdir 并确保可写。")
            case .webdav:
                Text("AList 示例：/dav/本地存储/PhoneBackup 。路径不存在时测试连接会尝试自动创建；须可写。主机只填 IP，不要带 http://。")
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
        Section("填写示例 · \(server.protocolKind.title)") {
            ForEach(helpLines, id: \.self) { line in
                Text("• \(line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var helpLines: [String] {
        switch server.protocolKind {
        case .sftp:
            return [
                "主机：192.168.1.10",
                "端口：22",
                "用户 / 密码：root 或普通用户",
                "基础路径：/mnt/sda1/PhoneBackup"
            ]
        case .webdav:
            return [
                "主机：只填 IP，如 192.168.1.10（不要写 http://）",
                "端口：AList 默认 5244（与 AList 设置里 WebDAV 端口一致）",
                "用户名/密码：AList / WebDAV 账号",
                "基础路径：/dav/存储名/PhoneBackup（存储名与 AList 里一致）",
                "若提示 404：路径未建好，测试会尝试自动创建",
                "若提示 405：多半路径不是 WebDAV 根，检查 /dav 前缀与端口",
                "内网自签 HTTPS：开 HTTPS 并勾选忽略证书"
            ]
        }
    }

    // MARK: - Actions

    private func save(andDismiss: Bool) {
        normalizeFields()
        serverStore.upsert(server, credentials: credentials)
        if andDismiss { dismiss() }
    }

    /// 清理主机/路径常见误填（scheme、尾斜杠、空白）
    private func normalizeFields() {
        server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.basePath = server.basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        server.username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)

        if server.protocolKind == .webdav {
            server.host = WebDAVStorageClient.sanitizeHost(server.host)
            // 若用户把完整 URL 贴进「基础路径」则拆出 path
            if server.basePath.lowercased().hasPrefix("http://")
                || server.basePath.lowercased().hasPrefix("https://"),
               let url = URL(string: server.basePath) {
                if let host = url.host, server.host.isEmpty { server.host = host }
                if let port = url.port, server.port <= 0 { server.port = port }
                server.basePath = url.path.isEmpty ? "/" : url.path
                if url.scheme?.lowercased() == "https" { server.useTLS = true }
            }
            if !server.basePath.hasPrefix("/") && !server.basePath.isEmpty {
                server.basePath = "/" + server.basePath
            }
        }

        if server.port <= 0 { server.port = server.protocolKind.defaultPort }
    }

    private func test() async {
        normalizeFields()
        save(andDismiss: false)
        isTesting = true
        testMessage = nil
        testOK = false
        defer { isTesting = false }

        do {
            let client = try StorageClientFactory.make(server: server, credentials: credentials)
            defer { Task { await client.close() } }
            try await client.testConnection()
            testOK = true
            testMessage = "\(server.protocolKind.title) 连接成功 ✓  可以开始备份"
        } catch {
            testOK = false
            testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
