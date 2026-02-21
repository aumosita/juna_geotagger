import SwiftUI
import MapKit
import QuickLookThumbnailing

/// 지도 패널 — GPX 트랙, 사진 위치 표시, 수동 위치 지정
struct MapPanelView: View {
    @Environment(MainViewModel.self) private var viewModel
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    @State private var selectedPhotoOnMap: PhotoItem?
    @State private var isManualMode = false
    @State private var manualPinCoord: CLLocationCoordinate2D?

    var body: some View {
        ZStack {
            if viewModel.photos.isEmpty && viewModel.gpxFiles.isEmpty {
                ContentUnavailableView {
                    Label("map.title", systemImage: "map")
                } description: {
                    Text("map.empty.desc")
                }
            } else {
                mapContent
            }
        }
    }

    // MARK: - Map Content

    private var mapContent: some View {
        MapReader { proxy in
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

                // 수동 지정 핀
                if let pin = manualPinCoord {
                    Annotation(String(localized: "map.manualPin"), coordinate: pin) {
                        Image(systemName: "mappin")
                            .font(.title)
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, isActive: true)
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
            .onTapGesture { screenPoint in
                guard isManualMode else { return }
                guard let coord = proxy.convert(screenPoint, from: .local) else { return }
                handleManualTap(coord)
            }
        }
        .overlay(alignment: .topTrailing) {
            mapOverlayControls
        }
        .overlay(alignment: .top) {
            if isManualMode {
                manualModeBanner
            }
        }
        .overlay(alignment: .bottom) {
            if let coord = manualPinCoord {
                manualPinConfirmation(coord)
                    .padding(.bottom, 50)
            } else if let photo = selectedPhotoOnMap, !isManualMode {
                PhotoMapPopover(photo: photo)
                    .padding(.bottom, 50)
            }
        }
        .onChange(of: viewModel.selectedPhotoIDs) { _, newIDs in
            guard !isManualMode else { return }
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

    // MARK: - Manual Tap

    private func handleManualTap(_ coord: CLLocationCoordinate2D) {
        withAnimation {
            manualPinCoord = coord
        }
    }

    // MARK: - Manual Mode Banner

    private var manualModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
            if viewModel.selectedPhotoIDs.isEmpty {
                Text("map.manual.selectFirst")
            } else {
                Text("map.manual.selected \(viewModel.selectedPhotoIDs.count)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .shadow(radius: 4)
        .padding(.top, 8)
    }

    // MARK: - Manual Pin Confirmation

    private func manualPinConfirmation(_ coord: CLLocationCoordinate2D) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("map.manual.title")
                    .font(.callout.bold())
                Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !viewModel.selectedPhotoIDs.isEmpty {
                    Text(String(localized: "map.manual.applyCount \(viewModel.selectedPhotoIDs.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("map.manual.apply") {
                viewModel.applyManualCoordinate(coord, to: viewModel.selectedPhotoIDs)
                withAnimation {
                    manualPinCoord = nil
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(viewModel.selectedPhotoIDs.isEmpty)

            Button("map.manual.write") {
                viewModel.applyManualCoordinate(coord, to: viewModel.selectedPhotoIDs)
                viewModel.writeSelected()
                withAnimation {
                    manualPinCoord = nil
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(viewModel.selectedPhotoIDs.isEmpty)

            Button("map.manual.cancel") {
                withAnimation {
                    manualPinCoord = nil
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
        .padding(.horizontal, 16)
    }

    // MARK: - Overlay Controls

    @ViewBuilder
    private var mapOverlayControls: some View {
        VStack(spacing: 8) {
            // 수동 지정 모드 토글
            Button {
                withAnimation {
                    isManualMode.toggle()
                    if !isManualMode {
                        manualPinCoord = nil
                    }
                }
            } label: {
                Image(systemName: isManualMode ? "hand.tap.fill" : "hand.tap")
                    .padding(8)
                    .background(
                        isManualMode ? AnyShapeStyle(.orange) : AnyShapeStyle(.regularMaterial),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(isManualMode ? .white : .primary)
            }
            .buttonStyle(.plain)
            .help(Text("map.manual.modeHelp"))

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
            .help(Text("map.fitAll"))

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
