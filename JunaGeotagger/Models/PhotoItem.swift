import Foundation
import CoreLocation

/// 사진 한 장의 메타데이터와 지오태깅 상태를 나타냅니다.
@Observable
final class PhotoItem: Identifiable, Hashable {
    let id = UUID()

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    let url: URL
    let filename: String

    /// 촬영 시각 (UTC)
    var dateTaken: Date?

    /// 기존 GPS 좌표 (EXIF에서 읽어온 값)
    var originalCoordinate: CLLocationCoordinate2D?

    /// GPX 매칭 또는 수동 지정된 GPS 좌표
    var matchedCoordinate: CLLocationCoordinate2D?
    var matchedAltitude: Double?

    /// 현재 상태
    var status: Status = .pending

    enum Status: String {
        case pending       // 아직 분석 전
        case hasGPS        // 이미 GPS 있음
        case matched       // GPX 매칭 성공
        case noTime        // 촬영 시각 없음
        case noMatch       // GPX 매칭 실패
        case written       // GPS 기록 완료
        case error         // 오류 발생
    }

    /// 지도에 표시할 최종 좌표
    var displayCoordinate: CLLocationCoordinate2D? {
        matchedCoordinate ?? originalCoordinate
    }

    init(url: URL) {
        self.url = url
        self.filename = url.lastPathComponent
    }
}
