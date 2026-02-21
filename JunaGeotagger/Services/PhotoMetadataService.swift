import Foundation
import CoreLocation
import ImageIO
import UniformTypeIdentifiers

/// Apple ImageIO 기반으로 사진 EXIF 메타데이터를 읽고 쓰는 서비스
enum PhotoMetadataService {

    // MARK: - 지원 확장자

    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png",
        "tiff", "tif", "dng", "arw", "cr2", "nef",
    ]

    static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - 메타데이터 읽기

    struct Metadata {
        var dateTaken: Date?
        var coordinate: CLLocationCoordinate2D?
        var altitude: Double?
        var hasGPS: Bool { coordinate != nil }
    }

    /// 사진 파일의 EXIF 메타데이터를 읽습니다.
    static func readMetadata(from url: URL) -> Metadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return Metadata()
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return Metadata()
        }

        var metadata = Metadata()

        // 촬영 시각 읽기
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateStr = exifDict[kCGImagePropertyExifDateTimeOriginal] as? String {
                metadata.dateTaken = parseEXIFDate(dateStr, offsetDict: exifDict)
            } else if let dateStr = exifDict[kCGImagePropertyExifDateTimeDigitized] as? String {
                metadata.dateTaken = parseEXIFDate(dateStr, offsetDict: exifDict)
            }
        }
        if metadata.dateTaken == nil,
           let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateStr = tiffDict[kCGImagePropertyTIFFDateTime] as? String {
            metadata.dateTaken = parseEXIFDate(dateStr, offsetDict: nil)
        }

        // GPS 읽기
        if let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gpsDict[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef] as? String,
               let lon = gpsDict[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef] as? String {
                let finalLat = latRef == "S" ? -lat : lat
                let finalLon = lonRef == "W" ? -lon : lon
                metadata.coordinate = CLLocationCoordinate2D(latitude: finalLat, longitude: finalLon)
            }
            if let alt = gpsDict[kCGImagePropertyGPSAltitude] as? Double {
                let altRef = gpsDict[kCGImagePropertyGPSAltitudeRef] as? Int ?? 0
                metadata.altitude = altRef == 1 ? -alt : alt
            }
        }

        return metadata
    }

    // MARK: - GPS 쓰기

    /// 사진 파일에 GPS 좌표를 기록합니다.
    /// ImageIO를 사용하여 원본 파일을 직접 수정합니다.
    @discardableResult
    static func writeGPS(to url: URL, coordinate: CLLocationCoordinate2D, altitude: Double = 0) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        guard let uti = CGImageSourceGetType(source) else { return false }

        let imageCount = CGImageSourceGetCount(source)

        // GPS 딕셔너리 생성
        let gpsDict: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef: coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef: coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude: abs(altitude),
            kCGImagePropertyGPSAltitudeRef: altitude >= 0 ? 0 : 1,
        ]


        // 임시 파일에 쓰기
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, uti, imageCount, nil
        ) else { return false }

        for i in 0..<imageCount {
            // 기존 프로퍼티를 가져와서 GPS만 덮어쓰기
            var props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] ?? [:]
            props[kCGImagePropertyGPSDictionary] = gpsDict

            CGImageDestinationAddImageFromSource(destination, source, i, props as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        // 원본 교체
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    // MARK: - EXIF 날짜 파싱

    private static func parseEXIFDate(_ dateStr: String, offsetDict: [CFString: Any]?) -> Date? {
        let trimmed = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "0000:00:00 00:00:00" else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // "2024:01:15 14:30:00" 형식
        for fmt in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = fmt
            formatter.timeZone = TimeZone.current // 기본: 로컬 타임존
            if let date = formatter.date(from: trimmed) {
                // Offset 정보가 있으면 적용
                if let offsetDict = offsetDict,
                   let offsetStr = (offsetDict[kCGImagePropertyExifOffsetTimeOriginal] as? String)
                    ?? (offsetDict[kCGImagePropertyExifOffsetTime] as? String) {
                    if let tz = parseTimezoneOffset(offsetStr) {
                        formatter.timeZone = tz
                        if let correctedDate = formatter.date(from: trimmed) {
                            return correctedDate
                        }
                    }
                }
                return date
            }
        }
        return nil
    }

    private static func parseTimezoneOffset(_ offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sign: Int = trimmed.hasPrefix("-") ? -1 : 1
        let digits = trimmed.dropFirst() // drop +/-
        let parts = digits.split(separator: ":")
        guard let hours = Int(parts[0]) else { return nil }
        let minutes = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let totalSeconds = sign * (hours * 3600 + minutes * 60)
        return TimeZone(secondsFromGMT: totalSeconds)
    }
}
