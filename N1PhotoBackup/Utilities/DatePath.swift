import Foundation

enum DatePath {
    static func remoteRelativePath(
        fileName: String,
        date: Date?,
        layout: StorageServer.FolderLayout
    ) -> String {
        switch layout {
        case .flat:
            return fileName
        case .yearMonth:
            let d = date ?? Date()
            let cal = Calendar.current
            let y = cal.component(.year, from: d)
            let m = cal.component(.month, from: d)
            return String(format: "%04d/%02d/%@", y, m, fileName)
        }
    }
}
