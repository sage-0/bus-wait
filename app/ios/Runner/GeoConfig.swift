import CoreLocation

/// ジオフェンス定義および判別パラメータ。
///
/// 座標値は設計書 3.1 / 3.2 が正。本実装では `GET /v1/config` による配信に置き換わるが
/// (設計書 6.2 / 不変条件11)、実測プロトタイプ段階ではサーバーが存在しないため定数として持つ。
enum GeoConfig {

    struct Region {
        let id: String
        let center: CLLocationCoordinate2D
        let radius: CLLocationDistance
    }

    struct StopPoint {
        let id: String
        let center: CLLocationCoordinate2D
    }

    /// 監視リージョンは3件のみ (設計書 3.1 / 不変条件5)。
    static let regions: [Region] = [
        Region(id: "campus_area",
               center: CLLocationCoordinate2D(latitude: 35.625514, longitude: 139.341597),
               radius: 150),
        Region(id: "st_hachioji",
               center: CLLocationCoordinate2D(latitude: 35.654167, longitude: 139.339194),
               radius: 150),
        Region(id: "st_minamino",
               center: CLLocationCoordinate2D(latitude: 35.631472, longitude: 139.329278),
               radius: 150),
    ]

    /// のりば座標。**これらはジオフェンスではなく測距用の座標である** (不変条件5)。
    /// 2点は約113mしか離れておらず、個別のリージョンを張ると発火が不安定になる (設計書 3.2)。
    static let stopPoints: [StopPoint] = [
        StopPoint(id: "campus_hachioji_bound",
                  center: CLLocationCoordinate2D(latitude: 35.625806, longitude: 139.342111)),
        StopPoint(id: "campus_minamino_bound",
                  center: CLLocationCoordinate2D(latitude: 35.625222, longitude: 139.341083)),
    ]

    /// 第2段判別のパラメータ (設計書 3.2)。いずれも較正対象 (未決事項#3)。
    static let resolutionThresholdMeters: CLLocationDistance = 35
    static let resolutionMaxDuration: TimeInterval = 60
    static let resolutionRetryInterval: TimeInterval = 10

    /// のりば判別の起点となるリージョン。
    static let campusAreaId = "campus_area"

    static func region(id: String) -> Region? {
        regions.first { $0.id == id }
    }

    static func stopPoint(id: String) -> StopPoint? {
        stopPoints.first { $0.id == id }
    }

    static func location(of coordinate: CLLocationCoordinate2D) -> CLLocation {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
