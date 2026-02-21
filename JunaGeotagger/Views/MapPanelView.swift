import SwiftUI
import MapKit
import QuickLookThumbnailing

/// 지도 패널 — GPX 트랙, 사진 위치 표시, 수동 위치 지정
struct MapPanelView: View {
    @Environment(MainViewModel.self) private var viewModel
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    @State private var selectedPhotoOnMap: PhotoItem?

    var body: some View {
        ZStack {
            if viewModel.photos.isEmpty && viewModel.gpxFiles.isEmpty {
                ContentUnavailableView {
                    Label("지도", systemImage: "map")
                } description: {
                    Text("사진과 GPX 파일을 불러오면\n지도에 트랙과 위치가 표시됩니다.")
                }
            } else {
                mapContent
            }
        }
    }

    private var mapContent: some View {
        Map(position: $mapCameraPosition, selection: $selectedPhotoOnMap) {
            // GPX 트랙 라인
            ForEach(viewModel.gpxFiles) { file in
                ForEach(Array(file.segments.enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: segment.points)
                        .stroke(.orange, lineWidth: 3)
                }
            }

            // 사진 위치 마커
            ForEach(viewModel.photos.filter { $0.displayCoordinate != nil }) { photo in
                if let coord = photo.displayCoordinate {
                    Annotation(photo.filename, coordinate: coord) {
                        PhotoMapPin(photo: photo)
                    }
                    .tag(photo)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapZoomStepper()
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 40)
        }
        .overlay(alignment: .topTrailing) {
            mapOverlayControls
        }
        .overlay(alignment: .bottom) {
            if let photo = selectedPhotoOnMap {
                PhotoMapPopover(photo: photo)
                    .padding(.bottom, 50)
            }
        }
        .onChange(of: viewModel.selectedPhotoIDs) { _, newIDs in
            guard newIDs.count == 1,
                  let id = newIDs.first,
                  let photo = viewModel.photos.first(where: { $0.id == id }),
                  let coord = photo.displayCoordinate else { return }

            withAnimation(.easeInOut(duration: 0.6)) {
                mapCameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 500,
                    longitudinalMeters: 500
                ))
                selectedPhotoOnMap = photo
            }
        }
    }

    @ViewBuilder
    private var mapOverlayControls: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation {
                    mapCameraPosition = .automatic
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("전체 보기")

            if !viewModel.gpxFiles.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(viewModel.gpxFiles) { file in
                        Text(file.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Photo Map Pin

struct PhotoMapPin: View {
    let photo: PhotoItem

    var body: some View {
        Circle()
            .fill(pinColor)
            .frame(width: 14, height: 14)
            .overlay {
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
            }
            .shadow(color: pinColor.opacity(0.5), radius: 3)
    }

    private var pinColor: Color {
        switch photo.status {
        case .hasGPS: .blue
        case .matched: .green
        case .written: .purple
        default: .red
        }
    }
}

// MARK: - Photo Map Popover

struct PhotoMapPopover: View {
    let photo: PhotoItem
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(photo.filename)
                    .font(.callout.bold())
                    .lineLimit(1)

                if let coord = photo.displayCoordinate {
                    Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let date = photo.dateTaken {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let request = QLThumbnailGenerator.Request(
            fileAt: photo.url,
            size: CGSize(width: 120, height: 120),
            scale: 2,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = rep.nsImage
        }
    }
}
