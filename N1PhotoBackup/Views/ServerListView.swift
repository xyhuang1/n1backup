import SwiftUI

struct ServerListView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @State private var editing: StorageServer?
    @State private var isCreating = false

    var body: some View {
        List {
            if serverStore.servers.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有 SFTP 服务器")
                            .font(.headline)
                        Text("点右上角「+」，填写主机、端口、账号密码与备份路径后保存。")
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
                    Text("已保存的 SFTP")
                } footer: {
                    Text("点按设为当前目标；备份使用带绿色 ✓ 的那一条。")
                }
            }

            Section {
                Button {
                    isCreating = true
                } label: {
                    Label("添加 SFTP 服务器", systemImage: "plus.circle.fill")
                }
            } footer: {
            Text("仅支持 SFTP。N1 上开启 SSH，并保证用户对 USB 目录可写。")
            }
        }
        .navigationTitle("SFTP 服务器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                ServerEditView(
                    server: StorageServer.blank(),
                    credentials: .empty,
                    isNew: true
                )
            }
        }
        .sheet(item: $editing) { server in
            NavigationStack {
                ServerEditView(
                    server: server,
                    credentials: serverStore.credentials(for: server.id),
                    isNew: false
                )
            }
        }
    }
}

private struct ServerRow: View {
    let server: StorageServer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.protocolKind.systemImage)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.displayTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(server.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}
