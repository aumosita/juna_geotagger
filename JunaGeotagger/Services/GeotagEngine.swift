import Foundation
import CoreLocation

/// GPX 트랙포인트와 사진 촬영 시각을 기반으로 GPS 위치를 보간하는 엔진
enum GeotagEngine {

    /// 기본 최대 보간 허용 시간 (초) - 1시간
    static let defaultMaxGapSeconds: TimeInterval = 3600

    /// 트랙포인트 리스트에서 사진 촬영 시각에 해당하는 GPS 위치를 선형 보간으로 계산합니다.
    ///
    /// 트랙포인트는 시간순으로 정렬되어 있어야 합니다.
    ///
    /// - Parameters:
    ///   - trackPoints: 시간순 정렬된 GPX 트랙포인트 배열
    ///   - photoTime: 사진 촬영 시각 (UTC)
    ///   - maxGap: 보간 허용 최대 시간 차이 (초)
    /// - Returns: 보간된 좌표와 고도, 또는 매칭 불가 시 nil
    static func interpolate(
        trackPoints: [GPXTrackPoint],
        photoTime: Date,
        maxGap: TimeInterval = defaultMaxGapSeconds
    ) -> (coordinate: CLLocationCoordinate2D, altitude: Double)? {
        guard !trackPoints.isEmpty else { return nil }

        // 이진 탐색으로 삽입 위치 찾기
        let idx = binarySearch(trackPoints: trackPoints, time: photoTime)

        // 정확히 일치
        if idx < trackPoints.count, trackPoints[idx].time == photoTime {
            let p = trackPoints[idx]
            return (p.coordinate, p.elevation)
        }

        // 범위 밖 (왼쪽)
        if idx == 0 {
            let gap = trackPoints[0].time.timeIntervalSince(photoTime)
            if gap <= maxGap {
                let p = trackPoints[0]
                return (p.coordinate, p.elevation)
            }
            return nil
        }

        // 범위 밖 (오른쪽)
        if idx >= trackPoints.count {
            let gap = photoTime.timeIntervalSince(trackPoints[trackPoints.count - 1].time)
            if gap <= maxGap {
                let p = trackPoints[trackPoints.count - 1]
                return (p.coordinate, p.elevation)
            }
            return nil
        }

        // 두 점 사이 보간
        let before = trackPoints[idx - 1]
        let after = trackPoints[idx]
        let totalGap = after.time.timeIntervalSince(before.time)

        if totalGap > maxGap { return nil }
        if totalGap == 0 { return (before.coordinate, before.elevation) }

        let elapsed = photoTime.timeIntervalSince(before.time)
        let ratio = elapsed / totalGap

        let lat = before.coordinate.latitude +
            (after.coordinate.latitude - before.coordinate.latitude) * ratio
        let lon = before.coordinate.longitude +
            (after.coordinate.longitude - before.coordinate.longitude) * ratio
        let alt = before.elevation + (after.elevation - before.elevation) * ratio

        return (CLLocationCoordinate2D(latitude: lat, longitude: lon), alt)
    }

    /// 여러 사진에 대해 일괄 매칭을 수행합니다.
    static func matchPhotos(
        _ photos: [PhotoItem],
        trackPoints: [GPXTrackPoint],
        maxGap: TimeInterval = defaultMaxGapSeconds
    ) {
        for photo in photos {
            // 이미 GPS가 있으면 건너뜀
            if photo.originalCoordinate != nil {
                photo.status = .hasGPS
                continue
            }

            // 촬영 시각이 없으면 건너뜀
            guard let dateTaken = photo.dateTaken else {
                photo.status = .noTime
                continue
            }

            // 보간 시도
            if let result = interpolate(trackPoints: trackPoints, photoTime: dateTaken, maxGap: maxGap) {
                photo.matchedCoordinate = result.coordinate
                photo.matchedAltitude = result.altitude
                photo.status = .matched
            } else {
                photo.status = .noMatch
            }
        }
    }

    // MARK: - 이진 탐색

    /// 시간순 정렬된 배열에서 삽입 위치를 찾습니다 (bisect_left와 동일)
    private static func binarySearch(trackPoints: [GPXTrackPoint], time: Date) -> Int {
        var lo = 0
        var hi = trackPoints.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if trackPoints[mid].time < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
