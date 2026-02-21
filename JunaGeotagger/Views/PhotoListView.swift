import SwiftUI
import QuickLookThumbnailing

/// 사진 목록 사이드바 뷰
struct PhotoListView: View {
    @Environment(MainViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        List(viewModel.photos, selection: $vm.selectedPhotoIDs) { photo in
            PhotoRowView(photo: photo)
                .tag(photo.id)
        }
        .listStyle(.sidebar)
        .overlay {
            if viewModel.photos.isEmpty {
                ContentUnavailableView {
                    Label("사진 없음", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("사진 파일을 드래그하거나\n툴바의 사진 추가 버튼을 사용하세요.")
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button("선택 항목 GPS 기록") {
                    viewModel.writeSelected()
                }
                .disabled(viewModel.isProcessing)
            }
        }
    }
}

// MARK: - Photo Row

struct PhotoRowView: View {
    let photo: PhotoItem
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            // 썸네일
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // 파일 정보
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    statusIcon(for: photo.status)
                    Text(statusLabel(for: photo.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let request = QLThumbnailGenerator.Request(
            fileAt: photo.url,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .thumbnail
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            self.thumbnail = representation.nsImage
        } catch {
            // 썸네일 생성 실패 — 무시
        }
    }

    @ViewBuilder
    private func statusIcon(for status: PhotoItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .hasGPS:
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.blue)
        case .matched:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .noTime:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .noMatch:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .written:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.purple)
        case .error:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func statusLabel(for status: PhotoItem.Status) -> String {
        switch status {
        case .pending: "분석 중..."
        case .hasGPS: "GPS 있음"
        case .matched: "매칭됨"
        case .noTime: "시각 없음"
        case .noMatch: "매칭 실패"
        case .written: "기록 완료"
        case .error: "오류"
        }
    }
}
