import SwiftUI
import QuickLookThumbnailing

/// 사진 목록 사이드바 뷰
struct PhotoListView: View {
    @Environment(MainViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 0) {
            // 필터 & 정렬 컨트롤
            VStack(spacing: 6) {
                Picker("photoList.filter", selection: $vm.photoFilter) {
                    ForEach(MainViewModel.PhotoFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                HStack {
                    Picker("photoList.sort", selection: $vm.photoSort) {
                        ForEach(MainViewModel.PhotoSort.allCases, id: \.self) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    Spacer()

                    Text(String(localized: "photoList.count \(viewModel.filteredPhotos.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 사진 목록
            List(viewModel.filteredPhotos, selection: $vm.selectedPhotoIDs) { photo in
                PhotoRowView(photo: photo, showDate: viewModel.photoSort == .dateTaken)
                    .tag(photo.id)
                    .draggable(photo.id.uuidString)
            }
            .listStyle(.sidebar)
            .overlay {
                if viewModel.photos.isEmpty {
                    ContentUnavailableView {
                        Label("photoList.noPhotos", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("photoList.noPhotos.desc")
                    }
                } else if viewModel.filteredPhotos.isEmpty {
                    ContentUnavailableView {
                        Label("photoList.noResults", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("photoList.noResults.desc \(viewModel.photoFilter.label)")
                    }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty {
                    Button("photoList.writeSelected") {
                        viewModel.writeSelected()
                    }
                    .disabled(viewModel.isProcessing)
                }
            }
        }
    }
}

// MARK: - Photo Row

struct PhotoRowView: View {
    let photo: PhotoItem
    var showDate: Bool = false
    @State private var thumbnail: NSImage?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

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

                if showDate, let date = photo.dateTaken {
                    Text(Self.dateFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
        case .pending: String(localized: "photoStatus.pending")
        case .hasGPS: String(localized: "photoStatus.hasGPS")
        case .matched: String(localized: "photoStatus.matched")
        case .noTime: String(localized: "photoStatus.noTime")
        case .noMatch: String(localized: "photoStatus.noMatch")
        case .written: String(localized: "photoStatus.written")
        case .error: String(localized: "photoStatus.error")
        }
    }
}
