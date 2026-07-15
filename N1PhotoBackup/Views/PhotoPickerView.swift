import SwiftUI
import PhotosUI

/// 备用封装：如需在自定义界面中嵌入 PhotosPicker 可用此视图
struct PhotoPickerView: View {
    @Binding var selection: [PhotosPickerItem]
    var maxSelection: Int = 200

    var body: some View {
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: maxSelection,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        ) {
            Label("从相册选择", systemImage: "photo.on.rectangle")
        }
    }
}
