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
            quickLookCoordinator.updatePhotos(viewModel.filteredPhotos, selectedIDs: viewModel.selectedPhotoIDs)
        }
    }

    // MARK: - QuickLook

    private func openQuickLook() {
        quickLookCoordinator.updatePhotos(viewModel.filteredPhotos, selectedIDs: viewModel.selectedPhotoIDs)
        quickLookCoordinator.togglePanel()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                viewModel.importPhotos()
            } label: {
                Label("toolbar.addPhotos", systemImage: "photo.on.rectangle.angled")
            }
            .help(Text("toolbar.addPhotos.help"))

            Button {
                viewModel.importGPX()
            } label: {
                Label("toolbar.addGPX", systemImage: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath")
            }
            .help(Text("toolbar.addGPX.help"))

            Divider()

            Button {
                viewModel.runMatching()
            } label: {
                Label("toolbar.runMatching", systemImage: "arrow.triangle.2.circlepath")
            }
            .help(Text("toolbar.runMatching.help"))
            .disabled(viewModel.allTrackPoints.isEmpty || viewModel.photos.isEmpty)

            Button {
                viewModel.writeAllMatched()
            } label: {
                Label("toolbar.writeAll", systemImage: "square.and.arrow.down.on.square")
            }
            .help(Text("toolbar.writeAll.help"))
            .disabled(viewModel.matchedCount == 0 || viewModel.isProcessing)

            Divider()

            Button {
                viewModel.clearAll()
            } label: {
                Label("toolbar.clear", systemImage: "trash")
            }
            .help(Text("toolbar.clear.help"))
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
                    statBadge(count: viewModel.hasGPSCount, label: String(localized: "statusBar.hasGPS"), color: .blue)
                    statBadge(count: viewModel.matchedCount, label: String(localized: "statusBar.matched"), color: .green)
                    statBadge(count: viewModel.writtenCount, label: String(localized: "statusBar.written"), color: .purple)
                    statBadge(count: viewModel.noMatchCount, label: String(localized: "statusBar.failed"), color: .red)
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
