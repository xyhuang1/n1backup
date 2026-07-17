import SwiftUI
import PhotosUI

struct HomeView: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @EnvironmentObject private var serverStore: ServerStore

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var showAllConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    serverCard
                    actionsCard
                    statusCard
                    tipsCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("N1 相册备份")
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .confirmationDialog(
                "备份全部相册可能很久。建议插电、连 Wi‑Fi，并保持 App 在前台。",
                isPresented: $showAllConfirm,
                titleVisibility: .visible
            ) {
                Button("开始全部备份", role: .destructive) {
                    Task { await runBackupAll() }
                }
                Button("取消", role: .cancel) {}
            }
            .onChange(of: pickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { await handlePicked(newItems) }
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("处理中…")
                            .padding(24)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("当前备份目标", systemImage: "externaldrive.connected.to.line.below")
                .font(.headline)

            if let s = serverStore.selectedServer {
                HStack(spacing: 10) {
                    Image(systemName: s.protocolKind.systemImage)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.displayTitle)
                            .font(.subheadline.weight(.semibold))
                        Text(s.summaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if serverStore.servers.count > 1 {
                    Picker("切换", selection: Binding(
                        get: { serverStore.selectedServerId ?? s.id },
                        set: { serverStore.select($0) }
                    )) {
                        ForEach(serverStore.servers) { item in
                            Text(item.displayTitle).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } else {
                Text("尚未配置 SFTP")
                    .foregroundStyle(.orange)
                Text("请到「设置 → SFTP 服务器」添加主机、账号与备份路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var actionsCard: some View {
        VStack(spacing: 12) {
            PhotosPicker(
                selection: $pickerItems,
                maxSelectionCount: 500,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                actionLabel("选择照片 / 视频上传", systemImage: "photo.on.rectangle.angled", color: .blue)
            }
            .disabled(serverStore.selectedServer == nil)

            Button {
                Task { await runBackupRecent(days: 30) }
            } label: {
                actionLabel("备份最近 30 天", systemImage: "calendar", color: .green)
            }
            .disabled(serverStore.selectedServer == nil)

            Button {
                Task { await runBackupRecent(days: 7) }
            } label: {
                actionLabel("备份最近 7 天", systemImage: "clock", color: .teal)
            }
            .disabled(serverStore.selectedServer == nil)

            Button(role: .destructive) {
                showAllConfirm = true
            } label: {
                actionLabel("备份全部相册", systemImage: "square.stack.3d.up", color: .orange)
            }
            .disabled(serverStore.selectedServer == nil)
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, systemImage: String, color: Color) -> some View {
        HStack {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 32)
            Text(title)
                .font(.body.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .opacity(serverStore.selectedServer == nil ? 0.5 : 1)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前队列")
                    .font(.headline)
                Spacer()
                Text(uploadManager.isRunning ? "上传中" : "空闲")
                    .font(.subheadline)
                    .foregroundStyle(uploadManager.isRunning ? .blue : .secondary)
            }
            ProgressView(value: uploadManager.overallProgress)
            HStack {
                Text(uploadManager.progressText)
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Toggle("跳过已存在", isOn: $uploadManager.skipExisting)
                    .labelsHidden()
                Text("跳过已存在")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = uploadManager.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("使用提示")
                .font(.headline)
            tipRow("设置里添加 SFTP：主机、端口 22、用户密码、/mnt/... 路径")
            tipRow("可保存多台 SFTP，主页可切换当前目标")
            tipRow("N1 上 mkdir 备份目录并保证 SSH 用户可写")
            tipRow("大量备份请插电并保持 App 前台")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func handlePicked(_ items: [PhotosPickerItem]) async {
        isLoading = true
        defer {
            isLoading = false
            pickerItems = []
        }
        do {
            try await PhotoLibraryService.ensureAuthorized()
            var ids: [String] = []
            for item in items {
                if let id = item.itemIdentifier {
                    ids.append(id)
                }
            }
            if ids.isEmpty {
                throw PhotoLibraryError.exportFailed("无法读取资源 ID，请将相册权限设为「所有照片」")
            }
            try await uploadManager.enqueueIdentifiers(ids)
        } catch {
            present(error)
        }
    }

    private func runBackupRecent(days: Int) async {
        isLoading = true
        let before = uploadManager.totalCount
        defer { isLoading = false }
        do {
            try await uploadManager.enqueueRecent(days: days)
            if uploadManager.totalCount == before {
                present(message: "最近 \(days) 天没有新的可备份照片/视频（或均已在队列中）")
            }
        } catch {
            present(error)
        }
    }

    private func runBackupAll() async {
        isLoading = true
        let before = uploadManager.totalCount
        defer { isLoading = false }
        do {
            try await uploadManager.enqueueAll()
            if uploadManager.totalCount == before {
                present(message: "没有新的可备份项目（相册为空或均已在队列中）")
            }
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showAlert = true
    }

    private func present(message: String) {
        alertMessage = message
        showAlert = true
    }
}
