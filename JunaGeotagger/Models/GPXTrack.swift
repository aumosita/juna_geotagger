import Foundation
import CoreLocation

/// GPX 트랙포인트 하나를 나타냅니다.
struct GPXTrackPoint: Sendable {
    let time: Date
    let coordinate: CLLocationCoordinate2D
    let elevation: Double
}

/// GPX 트랙 세그먼트 (연속된 점들의 집합)
struct GPXSegment: Sendable {
    let points: [CLLocationCoordinate2D]
}

/// GPX 파일 하나에서 파싱된 데이터
struct GPXFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let segments: [GPXSegment]
    let trackPoints: [GPXTrackPoint]
}
