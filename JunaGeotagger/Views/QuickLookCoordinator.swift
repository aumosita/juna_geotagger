import Quartz
import AppKit

/// macOS 네이티브 QuickLook 패널을 관리하는 코디네이터
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {

    private var previewURLs: [URL] = []
    private var startIndex: Int = 0

    /// 전체 사진 목록과 선택된 사진을 설정합니다.
    /// 전체 목록을 넘기므로 화살표로 모든 사진을 탐색할 수 있습니다.
    func updatePhotos(_ photos: [PhotoItem], selectedIDs: Set<UUID>) {
        previewURLs = photos.map { $0.url }

        // 선택된 사진의 인덱스를 시작점으로 설정
        if let firstSelectedID = selectedIDs.first,
           let idx = photos.firstIndex(where: { $0.id == firstSelectedID }) {
            startIndex = idx
        } else {
            startIndex = 0
        }

        // QuickLook 패널이 열려 있으면 새로고침
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

    /// 위/아래 화살표도 좌/우처럼 이전/다음 사진으로 이동
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }

        switch event.keyCode {
        case 126: // ↑ 위 화살표 → 이전
            if panel.currentPreviewItemIndex > 0 {
                panel.currentPreviewItemIndex -= 1
            }
            return true
        case 125: // ↓ 아래 화살표 → 다음
            if panel.currentPreviewItemIndex < previewURLs.count - 1 {
                panel.currentPreviewItemIndex += 1
            }
            return true
        default:
            return false
        }
    }
}
