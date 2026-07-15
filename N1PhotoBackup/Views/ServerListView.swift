import SwiftUI

struct ServerListView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @State private var editing: StorageServer?
    @State private var isCreating = false
    @State private var createProtocol: StorageProtocolKind = .webdav

    var body: some View {
        List {
            if serverStore.servers.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有存储服务器")
                            .font(.headline)
                        Text("点右上角「+」，选择 WebDAV / SMB / SFTP / FTP，填写授权信息后保存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(serverStore.servers) { server in
                        Button {
                            serverStore.select(server.id)
                        } label: {
                            ServerRow(
                                server: server,
                                isSelected: serverStore.selectedServerId == server.id
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                serverStore.delete(id: server.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editing = server
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                serverStore.select(server.id)
                            } label: {
                                Label("选用", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                        .contextMenu {
                            Button("设为当前备份目标") {
                                serverStore.select(server.id)
                            }
                            Button("编辑") { editing = server }
                            Button("删除", role: .destructive) {
                                serverStore.delete(id: server.id)
                            }
                        }
                    }
                } header: {
                    Text("已保存的连接")
                } footer: {
                    Text("点按设为当前目标；左滑编辑/删除。备份使用带绿色 ✓ 的那一条。")
                }
            }

            Section("添加新连接") {
                ForEach(StorageProtocolKind.allCases) { kind in
                    Button {
                        createProtocol = kind
                        isCreating = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.systemImage)
                                .font(.title3)
                                .frame(width: 28)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                    .foregroundStyle(.primary)
                                Text(kind.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("服务器")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(StorageProtocolKind.allCases) { kind in
                        Button {
                            createProtocol = kind
                            isCreating = true
                        } label: {
                            Label(kind.title, systemImage: kind.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                ServerEditView(
                    server: StorageServer.blank(protocol: createProtocol),
                    credentials: .empty,
                    isNew: true
                )
            }
            .environmentObject(serverStore)
        }
        .sheet(item: $editing) { server in
            NavigationStack {
                ServerEditView(
                    server: server,
                    credentials: serverStore.credentials(for: server),
                    isNew: false
                )
            }
            .environmentObject(serverStore)
        }
    }
}

private struct ServerRow: View {
    let server: StorageServer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.protocolKind.systemImage)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.displayTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }
                Text(server.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.left.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("左滑编辑")
        }
        .padding(.vertical, 4)
    }
}
