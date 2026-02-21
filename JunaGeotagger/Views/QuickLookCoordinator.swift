import Quartz
import AppKit

/// macOS 네이티브 QuickLook 패널을 관리하는 코디네이터
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {

    private var previewURLs: [URL] = []
    private var photoIDs: [UUID] = []
    private var startIndex: Int = 0

    /// 사이드바 선택 동기화 콜백
    var onSelectionChanged: ((UUID) -> Void)?

    /// 전체 사진 목록과 선택된 사진을 설정합니다.
    func updatePhotos(_ photos: [PhotoItem], selectedIDs: Set<UUID>) {
        previewURLs = photos.map { $0.url }
        photoIDs = photos.map { $0.id }

        if let firstSelectedID = selectedIDs.first,
           let idx = photos.firstIndex(where: { $0.id == firstSelectedID }) {
            startIndex = idx
        } else {
            startIndex = 0
        }

        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = startIndex
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
            panel.currentPreviewItemIndex = startIndex
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

    /// 모든 화살표 키를 처리하고 사이드바 선택을 동기화
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }

        switch event.keyCode {
        case 126, 123: // ↑ 또는 ← → 이전
            if panel.currentPreviewItemIndex > 0 {
                panel.currentPreviewItemIndex -= 1
                syncSelection(index: panel.currentPreviewItemIndex)
            }
            return true
        case 125, 124: // ↓ 또는 → → 다음
            if panel.currentPreviewItemIndex < previewURLs.count - 1 {
                panel.currentPreviewItemIndex += 1
                syncSelection(index: panel.currentPreviewItemIndex)
            }
            return true
        default:
            return false
        }
    }

    private func syncSelection(index: Int) {
        guard index >= 0 && index < photoIDs.count else { return }
        onSelectionChanged?(photoIDs[index])
    }
}
