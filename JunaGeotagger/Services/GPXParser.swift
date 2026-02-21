import Foundation
import CoreLocation

/// GPX XML 파일을 파싱하여 트랙 데이터를 추출합니다.
final class GPXParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    // MARK: - Public

    /// GPX 파일 하나를 파싱합니다.
    static func parse(url: URL) throws -> GPXFile {
        let data = try Data(contentsOf: url)
        let parser = GPXParser()
        parser.fileURL = url
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse() else {
            throw GPXParserError.parseFailed(url.lastPathComponent)
        }
        return parser.buildResult()
    }

    /// 여러 GPX 파일을 파싱하고, 모든 트랙포인트를 시간순으로 정렬하여 반환합니다.
    static func parseFiles(urls: [URL]) -> (files: [GPXFile], allPoints: [GPXTrackPoint]) {
        var files: [GPXFile] = []
        var allPoints: [GPXTrackPoint] = []

        for url in urls {
            guard let file = try? parse(url: url) else { continue }
            allPoints.append(contentsOf: file.trackPoints)
            files.append(file)
        }

        allPoints.sort { $0.time < $1.time }
        return (files, allPoints)
    }

    // MARK: - Private State

    private var fileURL: URL = URL(fileURLWithPath: "/")

    // Parsing state
    private var currentElement = ""
    private var currentText = ""

    // Track hierarchy
    private var currentTrackName: String?
    private var segments: [GPXSegment] = []
    private var currentSegmentPoints: [CLLocationCoordinate2D] = []
    private var trackPoints: [GPXTrackPoint] = []

    // Current point being parsed (trkpt or wpt)
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentElevation: Double?
    private var currentTime: Date?
    private var inTrackPoint = false
    private var inWaypoint = false

    // Date formatter for GPX ISO 8601 times
    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
        ]
        return formats.map { fmt in
            let df = DateFormatter()
            df.dateFormat = fmt
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            return df
        }
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try ISO8601DateFormatter first
        if let d = Self.isoFormatter.date(from: trimmed) { return d }
        // Fallback to DateFormatter variants
        for df in Self.dateFormatters {
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    private func buildResult() -> GPXFile {
        GPXFile(
            url: fileURL,
            name: currentTrackName ?? fileURL.deletingPathExtension().lastPathComponent,
            segments: segments,
            trackPoints: trackPoints.sorted { $0.time < $1.time }
        )
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "trkpt", "wpt":
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                currentLat = lat
                currentLon = lon
            }
            currentElevation = nil
            currentTime = nil
            inTrackPoint = (elementName == "trkpt")
            inWaypoint = (elementName == "wpt")

        case "trkseg":
            currentSegmentPoints = []

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "name":
            if currentTrackName == nil && !inTrackPoint && !inWaypoint {
                currentTrackName = text
            }

        case "ele":
            currentElevation = Double(text)

        case "time":
            if inTrackPoint || inWaypoint {
                currentTime = parseDate(text)
            }

        case "trkpt":
            if let lat = currentLat, let lon = currentLon {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                currentSegmentPoints.append(coord)

                if let time = currentTime {
                    trackPoints.append(GPXTrackPoint(
                        time: time,
                        coordinate: coord,
                        elevation: currentElevation ?? 0
                    ))
                }
            }
            inTrackPoint = false

        case "wpt":
            if let lat = currentLat, let lon = currentLon, let time = currentTime {
                trackPoints.append(GPXTrackPoint(
                    time: time,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    elevation: currentElevation ?? 0
                ))
            }
            inWaypoint = false

        case "trkseg":
            if !currentSegmentPoints.isEmpty {
                segments.append(GPXSegment(points: currentSegmentPoints))
            }

        default:
            break
        }
    }
}

// MARK: - Errors

enum GPXParserError: LocalizedError {
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let name):
            return "GPX 파일 파싱 실패: \(name)"
        }
    }
}
