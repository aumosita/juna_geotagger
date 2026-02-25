import SwiftUI
import UniformTypeIdentifiers
import Quartz

/// 메인 콘텐츠 뷰 — 3열 레이아웃 (사진 목록 | 지도 | 상세정보)
struct ContentView: View {
    @Environment(MainViewModel.self) private var viewModel
    @State private var quickLookCoordinator = QuickLookCoordinator()

    private var showDuplicateAlert: Binding<Bool> {
        Binding(
            get: { viewModel.duplicateAlertMessage != nil },
            set: { if !$0 { viewModel.duplicateAlertMessage = nil } }
        )
    }

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
        .dropDestination(for: URL.self) { urls, _ in
            var photoURLs: [URL] = []
            var gpxURLs: [URL] = []

            for url in urls {
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
            return !photoURLs.isEmpty || !gpxURLs.isEmpty
        }
        .overlay(alignment: .bottom) {
            StatusBarView()
        }
        .overlay {
            if viewModel.isLoadingPhotos || viewModel.isLoadingGPX {
                LoadingOverlayView(
                    isLoadingPhotos: viewModel.isLoadingPhotos,
                    isLoadingGPX: viewModel.isLoadingGPX
                )
            }
        }
        .alert(
            String(localized: "alert.duplicateTitle"),
            isPresented: showDuplicateAlert
        ) {
            Button("OK") { viewModel.duplicateAlertMessage = nil }
        } message: {
            Text(viewModel.duplicateAlertMessage ?? "")
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
        quickLookCoordinator.onSelectionChanged = { [weak viewModel] photoID in
            viewModel?.selectedPhotoIDs = [photoID]
        }
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

// MARK: - Loading Overlay

struct LoadingOverlayView: View {
    let isLoadingPhotos: Bool
    let isLoadingGPX: Bool

    private var message: String {
        if isLoadingPhotos && isLoadingGPX {
            return String(localized: "loading.all")
        } else if isLoadingPhotos {
            return String(localized: "loading.photos")
        } else {
            return String(localized: "loading.gpx")
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                Text(message)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: isLoadingPhotos)
        .animation(.easeInOut(duration: 0.2), value: isLoadingGPX)
    }
}
