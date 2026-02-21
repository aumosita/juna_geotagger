import SwiftUI
import UniformTypeIdentifiers
import Quartz

/// 메인 콘텐츠 뷰 — 3열 레이아웃 (사진 목록 | 지도 | 상세정보)
struct ContentView: View {
    @Environment(MainViewModel.self) private var viewModel
    @State private var quickLookCoordinator = QuickLookCoordinator()

    var body: some View {
        NavigationSplitView {
            PhotoListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            MapPanelView()
        }
        .toolbar {
            toolbarContent
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(alignment: .bottom) {
            StatusBarView()
        }
        .onKeyPress(.space) {
            openQuickLook()
            return .handled
        }
        .onChange(of: viewModel.selectedPhotoIDs) { _, _ in
            quickLookCoordinator.updatePhotos(viewModel.photos, selectedIDs: viewModel.selectedPhotoIDs)
        }
    }

    // MARK: - QuickLook

    private func openQuickLook() {
        quickLookCoordinator.updatePhotos(viewModel.photos, selectedIDs: viewModel.selectedPhotoIDs)
        quickLookCoordinator.togglePanel()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                viewModel.importPhotos()
            } label: {
                Label("사진 추가", systemImage: "photo.on.rectangle.angled")
            }
            .help("사진 파일 또는 폴더를 선택합니다")

            Button {
                viewModel.importGPX()
            } label: {
                Label("GPX 추가", systemImage: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath")
            }
            .help("GPX 파일을 선택합니다")

            Divider()

            Button {
                viewModel.runMatching()
            } label: {
                Label("매칭 실행", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("GPX 트랙과 사진을 매칭합니다")
            .disabled(viewModel.allTrackPoints.isEmpty || viewModel.photos.isEmpty)

            Button {
                viewModel.writeAllMatched()
            } label: {
                Label("모두 기록", systemImage: "square.and.arrow.down.on.square")
            }
            .help("매칭된 모든 사진에 GPS를 기록합니다")
            .disabled(viewModel.matchedCount == 0 || viewModel.isProcessing)

            Divider()

            Button {
                viewModel.clearAll()
            } label: {
                Label("초기화", systemImage: "trash")
            }
            .help("모든 사진과 GPX를 제거합니다")
        }
    }

    // MARK: - Drag & Drop

    private func handleDrop(providers: [NSItemProvider]) {
        Task { @MainActor in
            var photoURLs: [URL] = []
            var gpxURLs: [URL] = []

            for provider in providers {
                guard let url = await loadURL(from: provider) else { continue }

                if url.pathExtension.lowercased() == "gpx" {
                    gpxURLs.append(url)
                } else if PhotoMetadataService.isSupported(url: url) {
                    photoURLs.append(url)
                } else {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                       isDir.boolValue {
                        photoURLs.append(url)
                    }
                }
            }

            if !photoURLs.isEmpty {
                viewModel.addPhotos(urls: photoURLs)
            }
            if !gpxURLs.isEmpty {
                viewModel.addGPXFiles(urls: gpxURLs)
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    @Environment(MainViewModel.self) private var viewModel

    var body: some View {
        HStack(spacing: 16) {
            if viewModel.isProcessing {
                ProgressView()
                    .controlSize(.small)
            }

            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if !viewModel.photos.isEmpty {
                HStack(spacing: 12) {
                    statBadge(count: viewModel.hasGPSCount, label: "GPS 있음", color: .blue)
                    statBadge(count: viewModel.matchedCount, label: "매칭됨", color: .green)
                    statBadge(count: viewModel.writtenCount, label: "기록됨", color: .purple)
                    statBadge(count: viewModel.noMatchCount, label: "실패", color: .red)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func statBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label): \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
