import Foundation
import CoreLocation
import QuickLookThumbnailing
import AppKit

/// 메인 앱 상태를 관리하는 ViewModel
@Observable
@MainActor
final class MainViewModel {

    // MARK: - State

    var photos: [PhotoItem] = []
    var gpxFiles: [GPXFile] = []
    var allTrackPoints: [GPXTrackPoint] = []

    var selectedPhotoIDs: Set<UUID> = []
    var isProcessing = false
    var statusMessage = String(localized: "status.ready")
    var maxGapSeconds: TimeInterval = GeotagEngine.defaultMaxGapSeconds

    /// 지도에서 선택한 좌표 (수동 지오태깅용)
    var manualCoordinate: CLLocationCoordinate2D?

    /// 필터 & 정렬
    var photoFilter: PhotoFilter = .all
    var photoSort: PhotoSort = .filename

    enum PhotoFilter: String, CaseIterable {
        case all, hasGPS, matched, noMatch, noTime, written

        var label: String {
            switch self {
            case .all:     String(localized: "filter.all")
            case .hasGPS:  String(localized: "filter.hasGPS")
            case .matched: String(localized: "filter.matched")
            case .noMatch: String(localized: "filter.noMatch")
            case .noTime:  String(localized: "filter.noTime")
            case .written: String(localized: "filter.written")
            }
        }
    }

    enum PhotoSort: String, CaseIterable {
        case filename, dateTaken

        var label: String {
            switch self {
            case .filename:  String(localized: "sort.filename")
            case .dateTaken: String(localized: "sort.dateTaken")
            }
        }
    }

    /// 필터 + 정렬이 적용된 사진 목록
    var filteredPhotos: [PhotoItem] {
        let filtered: [PhotoItem]
        switch photoFilter {
        case .all:      filtered = photos
        case .hasGPS:   filtered = photos.filter { $0.status == .hasGPS }
        case .matched:  filtered = photos.filter { $0.status == .matched }
        case .noMatch:  filtered = photos.filter { $0.status == .noMatch || $0.status == .noTime }
        case .noTime:   filtered = photos.filter { $0.status == .noTime }
        case .written:  filtered = photos.filter { $0.status == .written }
        }

        switch photoSort {
        case .filename:
            return filtered.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .dateTaken:
            return filtered.sorted {
                ($0.dateTaken ?? .distantFuture) < ($1.dateTaken ?? .distantFuture)
            }
        }
    }

    // MARK: - Computed

    var photosWithGPS: [PhotoItem] {
        photos.filter { $0.displayCoordinate != nil }
    }

    var photosWithoutGPS: [PhotoItem] {
        photos.filter { $0.displayCoordinate == nil }
    }

    var matchedCount: Int {
        photos.filter { $0.status == .matched }.count
    }

    var hasGPSCount: Int {
        photos.filter { $0.status == .hasGPS }.count
    }

    var noMatchCount: Int {
        photos.filter { $0.status == .noMatch || $0.status == .noTime }.count
    }

    var writtenCount: Int {
        photos.filter { $0.status == .written }.count
    }

    // MARK: - 사진 가져오기

    /// Open Panel로 사진 파일 선택
    func importPhotos() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "panel.selectPhotos")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = PhotoMetadataService.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        guard panel.runModal() == .OK else { return }
        addPhotos(urls: panel.urls)
    }

    /// URL 배열에서 사진 추가 (드래그 앤 드롭 또는 Open Panel)
    func addPhotos(urls: [URL]) {
        var fileURLs: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // 디렉토리면 안에 있는 이미지 파일들을 추가
                    if let enumerator = FileManager.default.enumerator(
                        at: url, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                    ) {
                        for case let fileURL as URL in enumerator {
                            if PhotoMetadataService.isSupported(url: fileURL) {
                                fileURLs.append(fileURL)
                            }
                        }
                    }
                } else if PhotoMetadataService.isSupported(url: url) {
                    fileURLs.append(url)
                }
            }
        }

        // 중복 방지
        let existingPaths = Set(photos.map { $0.url.path })
        let newURLs = fileURLs.filter { !existingPaths.contains($0.path) }

        guard !newURLs.isEmpty else {
            statusMessage = String(localized: "status.noNewPhotos")
            return
        }

        let newPhotos = newURLs.map { PhotoItem(url: $0) }
        photos.append(contentsOf: newPhotos)

        statusMessage = String(localized: "status.photosAdded \(newPhotos.count)")

        // 백그라운드에서 메타데이터 읽기
        Task {
            await loadMetadata(for: newPhotos)
            runMatching()
        }
    }

    // MARK: - GPX 가져오기

    /// Open Panel로 GPX 파일 선택
    func importGPX() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "panel.selectGPX")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx")].compactMap { $0 }

        guard panel.runModal() == .OK else { return }
        addGPXFiles(urls: panel.urls)
    }

    /// URL 배열에서 GPX 파일 추가
    func addGPXFiles(urls: [URL]) {
        let gpxURLs = urls.filter { $0.pathExtension.lowercased() == "gpx" }
        guard !gpxURLs.isEmpty else { return }

        // 중복 방지
        let existingPaths = Set(gpxFiles.map { $0.url.path })
        let newURLs = gpxURLs.filter { !existingPaths.contains($0.path) }
        guard !newURLs.isEmpty else {
            statusMessage = String(localized: "status.noNewGPX")
            return
        }

        let urlsToProcess = newURLs
        Task {
            let (newFiles, _) = await Task.detached {
                GPXParser.parseFiles(urls: urlsToProcess)
            }.value

            self.gpxFiles.append(contentsOf: newFiles)
            // 전체 트랙포인트 재생성
            self.allTrackPoints = self.gpxFiles.flatMap { $0.trackPoints }
                .sorted { $0.time < $1.time }

            let pointCount = newFiles.reduce(0) { $0 + $1.trackPoints.count }
            self.statusMessage = String(localized: "status.gpxLoaded \(newFiles.count) \(pointCount)")

            self.runMatching()
        }
    }

    // MARK: - 매칭

    /// 로드된 GPX와 사진을 매칭합니다.
    func runMatching() {
        guard !allTrackPoints.isEmpty else { return }

        let pendingPhotos = photos.filter {
            $0.status == .pending || $0.status == .noMatch || $0.status == .matched
        }
        guard !pendingPhotos.isEmpty else { return }

        GeotagEngine.matchPhotos(pendingPhotos, trackPoints: allTrackPoints, maxGap: maxGapSeconds)

        let matched = photos.filter { $0.status == .matched }.count
        statusMessage = String(localized: "status.matchResult \(matched) \(photos.count)")
    }

    // MARK: - GPS 기록

    /// 매칭된 모든 사진에 GPS를 기록합니다.
    func writeAllMatched() {
        let targets = photos.filter { $0.status == .matched }
        guard !targets.isEmpty else {
            statusMessage = String(localized: "status.noMatchedToWrite")
            return
        }
        writeGPS(to: targets)
    }

    /// 선택된 사진에 GPS를 기록합니다.
    func writeSelected() {
        let targets = photos.filter {
            selectedPhotoIDs.contains($0.id) && $0.status == .matched
        }
        guard !targets.isEmpty else {
            statusMessage = String(localized: "status.noMatchedInSelection")
            return
        }
        writeGPS(to: targets)
    }

    /// 특정 사진들에 GPS를 기록합니다 (드래그 앤 드롭용).
    func writeGPSPublic(to targets: [PhotoItem]) {
        writeGPS(to: targets)
    }

    /// 수동으로 선택한 좌표를 사진에 기록합니다.
    func applyManualCoordinate(_ coord: CLLocationCoordinate2D, to photoIDs: Set<UUID>) {
        let targets = photos.filter { photoIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        for photo in targets {
            photo.matchedCoordinate = coord
            photo.matchedAltitude = 0
            photo.status = .matched
        }

        statusMessage = String(localized: "status.manualApplied \(targets.count)")
    }

    private func writeGPS(to targets: [PhotoItem]) {
        isProcessing = true
        statusMessage = String(localized: "status.writing \(0) \(targets.count)")

        // MainActor에서 필요한 데이터를 미리 추출
        struct WriteJob: Sendable {
            let index: Int
            let url: URL
            let lat: Double
            let lon: Double
            let alt: Double
        }

        var jobs: [WriteJob] = []
        for (i, photo) in targets.enumerated() {
            guard let coord = photo.matchedCoordinate else { continue }
            let alt = photo.matchedAltitude ?? 0
            jobs.append(WriteJob(index: i, url: photo.url, lat: coord.latitude, lon: coord.longitude, alt: alt))
        }

        let totalCount = targets.count
        Task {
            var successCount = 0
            for job in jobs {
                let coord = CLLocationCoordinate2D(latitude: job.lat, longitude: job.lon)
                let success = await Task.detached {
                    PhotoMetadataService.writeGPS(to: job.url, coordinate: coord, altitude: job.alt)
                }.value

                let photo = targets[job.index]
                if success {
                    photo.originalCoordinate = coord
                    photo.status = .written
                    successCount += 1
                } else {
                    photo.status = .error
                }
                self.statusMessage = String(localized: "status.writing \(job.index + 1) \(totalCount)")
            }

            self.isProcessing = false
            self.statusMessage = String(localized: "status.writeComplete \(successCount) \(totalCount)")
        }
    }

    // MARK: - 초기화

    func clearAll() {
        photos.removeAll()
        gpxFiles.removeAll()
        allTrackPoints.removeAll()
        selectedPhotoIDs.removeAll()
        manualCoordinate = nil
        statusMessage = String(localized: "status.ready")
    }

    // MARK: - Private

    private func loadMetadata(for items: [PhotoItem]) async {
        for photo in items {
            let metadata = PhotoMetadataService.readMetadata(from: photo.url)
            photo.dateTaken = metadata.dateTaken
            photo.originalCoordinate = metadata.coordinate

            if metadata.hasGPS {
                photo.status = .hasGPS
            }
        }
    }
}

// MARK: - UTType extension
import UniformTypeIdentifiers
