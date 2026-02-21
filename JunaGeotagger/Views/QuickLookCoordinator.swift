import Quartz
import AppKit

/// macOS 네이티브 QuickLook 패널을 관리하는 코디네이터
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {

    private var previewURLs: [URL] = []
    private var currentIndex: Int = 0

    /// 선택된 사진 정보를 업데이트합니다.
    func updatePhotos(_ photos: [PhotoItem], selectedIDs: Set<UUID>) {
        let selected = photos.filter { selectedIDs.contains($0.id) }
        previewURLs = selected.map { $0.url }
        currentIndex = 0

        // QuickLook 패널이 열려 있으면 새로고침
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    /// QuickLook 패널을 토글합니다.
    func togglePanel() {
        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            guard !previewURLs.isEmpty else { return }
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}
