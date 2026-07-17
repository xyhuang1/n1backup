import SwiftUI

struct ServerListView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @State private var editing: StorageServer?
    @State private var isCreating = false
    @State private var createProtocol: StorageProtocolKind = .sftp

    var body: some View {
        List {
            if serverStore.servers.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有备份服务器")
                            .font(.headline)
                        Text("点右上角「+」，选择 SFTP 或 WebDAV，填写主机与备份路径后保存。")
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
                    Text("已保存的服务器")
                } footer: {
                    Text("点按设为当前目标；备份使用带绿色 ✓ 的那一条。支持 SFTP 与 WebDAV。")
                }
            }

            Section {
                Button {
                    createProtocol = .sftp
                    isCreating = true
                } label: {
                    Label("添加 SFTP", systemImage: "terminal")
                }
                Button {
                    createProtocol = .webdav
                    isCreating = true
                } label: {
                    Label("添加 WebDAV", systemImage: "globe")
                }
            } footer: {
                Text("WebDAV（AList 等）在 N1 上通常比多路 SFTP 更稳、更省 CPU。")
            }
        }
        .navigationTitle("备份服务器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        createProtocol = .sftp
                        isCreating = true
                    } label: {
                        Label("SFTP", systemImage: "terminal")
                    }
                    Button {
                        createProtocol = .webdav
                        isCreating = true
                    } label: {
                        Label("WebDAV", systemImage: "globe")
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
