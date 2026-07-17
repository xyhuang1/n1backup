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

    var body: some View {
        Form {
            identitySection
            connectionSection
            authSection
            pathSection
            actionSection
            helpSection
        }
        .navigationTitle(isNew ? "新建 SFTP" : "编辑 SFTP")
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
        .confirmationDialog("删除此服务器？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                serverStore.delete(id: server.id)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var identitySection: some View {
        Section("显示名称") {
            TextField("例如：家里 N1", text: $server.name)
        }
    }

    private var connectionSection: some View {
        Section("连接") {
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
        } footer: {
            Text("N1 / iStoreOS 一般开启系统 SSH，端口 22。")
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
        } header: {
            Text("授权")
        } footer: {
            Text("密码与私钥保存在系统钥匙串。推荐密码登录；私钥需 OpenSSH 格式（-----BEGIN OPENSSH PRIVATE KEY-----）。")
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
            Text("SSH 用户可见的绝对路径，如 /mnt/sda1/PhoneBackup。请先 mkdir 并确保可写。")
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
        Section("填写示例") {
            Text("• 主机：192.168.1.10")
            Text("• 端口：22")
            Text("• 用户 / 密码：root 或普通用户")
            Text("• 基础路径：/mnt/sda1/PhoneBackup")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save(andDismiss: Bool) {
        server.protocolKind = .sftp
        server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.basePath = server.basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if server.port <= 0 { server.port = 22 }
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
            defer { Task { await client.close() } }
            try await client.testConnection()
            testOK = true
            testMessage = "SFTP 连接成功 ✓  可以开始备份"
        } catch {
            testOK = false
            testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
