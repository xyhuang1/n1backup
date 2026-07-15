import SwiftUI
import Photos

struct UploadQueueView: View {
    @EnvironmentObject private var uploadManager: UploadManager

    var body: some View {
        NavigationStack {
            Group {
                if uploadManager.items.isEmpty {
                    ContentUnavailableView(
                        "队列为空",
                        systemImage: "tray",
                        description: Text("在「备份」页选择照片或启动自动备份")
                    )
                } else {
                    List {
                        Section {
                            HStack {
                                Text("进度")
                                Spacer()
                                Text(uploadManager.progressText)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            ProgressView(value: uploadManager.overallProgress)
                        }

                        Section("任务 (\(uploadManager.items.count))") {
                            ForEach(uploadManager.items) { item in
                                UploadRow(item: item)
                            }
                        }
                    }
                }
            }
            .navigationTitle("上传队列")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("重试失败项", systemImage: "arrow.clockwise") {
                            uploadManager.retryFailed()
                        }
                        Button("清除已完成", systemImage: "checkmark.circle") {
                            uploadManager.clearFinished()
                        }
                        Button("清空全部", systemImage: "trash", role: .destructive) {
                            uploadManager.clearAll()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

private struct UploadRow: View {
    let item: UploadItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(item.remoteRelativePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Text(item.status.label)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                if case .uploading(let p) = item.status {
                    ProgressView(value: p)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch item.status {
        case .succeeded: return "checkmark.circle.fill"
        case .skipped: return "arrow.right.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .uploading: return "arrow.up.circle.fill"
        default:
            return item.mediaType == .video ? "video.fill" : "photo.fill"
        }
    }

    private var iconColor: Color {
        switch item.status {
        case .succeeded: return .green
        case .skipped: return .gray
        case .failed: return .red
        case .uploading: return .blue
        default: return .secondary
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .failed: return .red
        case .succeeded: return .green
        case .skipped: return .secondary
        default: return .primary
        }
    }
}
