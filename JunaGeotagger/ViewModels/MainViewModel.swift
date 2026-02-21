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
    var statusMessage = "사진과 GPX 파일을 불러오세요."
    var maxGapSeconds: TimeInterval = GeotagEngine.defaultMaxGapSeconds

    /// 지도에서 선택한 좌표 (수동 지오태깅용)
    var manualCoordinate: CLLocationCoordinate2D?

    /// 필터 & 정렬
    var photoFilter: PhotoFilter = .all
    var photoSort: PhotoSort = .filename

    enum PhotoFilter: String, CaseIterable {
        case all       = "전체"
        case hasGPS    = "GPS 있음"
        case matched   = "매칭됨"
        case noMatch   = "매칭 실패"
        case noTime    = "시각 없음"
        case written   = "기록 완료"
    }

    enum PhotoSort: String, CaseIterable {
        case filename  = "파일명"
        case dateTaken = "촬영 시각"
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
        panel.title = "사진 선택"
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
            statusMessage = "추가할 새 사진이 없습니다."
            return
        }

        let newPhotos = newURLs.map { PhotoItem(url: $0) }
        photos.append(contentsOf: newPhotos)

        statusMessage = "\(newPhotos.count)장의 사진을 추가했습니다."

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
        panel.title = "GPX 파일 선택"
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
            statusMessage = "추가할 새 GPX 파일이 없습니다."
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
            self.statusMessage = "\(newFiles.count)개 GPX 파일 로드 (트랙포인트 \(pointCount)개)"

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
        statusMessage = "\(matched)장 매칭 완료 / 전체 \(photos.count)장"
    }

    // MARK: - GPS 기록

    /// 매칭된 모든 사진에 GPS를 기록합니다.
    func writeAllMatched() {
        let targets = photos.filter { $0.status == .matched }
        guard !targets.isEmpty else {
            statusMessage = "기록할 매칭된 사진이 없습니다."
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
            statusMessage = "선택된 사진 중 매칭된 것이 없습니다."
            return
        }
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

        statusMessage = "\(targets.count)장에 수동 좌표 지정 완료"
    }

    private func writeGPS(to targets: [PhotoItem]) {
        isProcessing = true
        statusMessage = "GPS 기록 중... (0/\(targets.count))"

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
                self.statusMessage = "GPS 기록 중... (\(job.index + 1)/\(totalCount))"
            }

            self.isProcessing = false
            self.statusMessage = "GPS 기록 완료: \(successCount)/\(totalCount)장 성공"
        }
    }

    // MARK: - 초기화

    func clearAll() {
        photos.removeAll()
        gpxFiles.removeAll()
        allTrackPoints.removeAll()
        selectedPhotoIDs.removeAll()
        manualCoordinate = nil
        statusMessage = "사진과 GPX 파일을 불러오세요."
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
