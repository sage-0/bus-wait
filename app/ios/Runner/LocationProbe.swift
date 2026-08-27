import CoreLocation
import Foundation

/// 実測プロトタイプの中核 (設計書 11章)。
///
/// 検知遅延を測るには「真の境界通過時刻」の基準が必要になる。そのため
/// **リージョン監視と前景の高精度測位を同時に走らせる**。
///
///   リージョン監視 → didEnter/ExitRegion の発火時刻            = 検知時刻
///   高精度測位     → 中心からの距離が半径150mを跨いだ時刻       = 真の通過時刻
///                                                差 = 検知遅延
///
/// 跨いだ時刻の算出は**サーバー側 (後処理) で行う**。端末は距離を観測値として記録するだけで、
/// 通過の判定はしない (不変条件2)。唯一の例外がのりば判別であり、これは設計書 3.2 が
/// 明示的に端末側の責務と定めている。
final class LocationProbe: NSObject {

    static let shared = LocationProbe()

    private let manager = CLLocationManager()
    private var running = false

    /// のりば判別 (設計書 3.2 第2段) の進行状態。
    private var resolutionStartedAt: Date?
    private var resolutionAttempts = 0
    private var lastAttemptAt: Date?
    private var resolutionTimer: Timer?

    private var latestLocation: CLLocation?
    private var latestDistances: [String: Double] = [:]

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        // 測定が途中で止まると遅延を測れないため、OS による自動停止を無効化する。
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - 公開 API (MethodChannel から呼ばれる)

    func requestPermission(level: String) {
        switch level {
        case "always":
            manager.requestAlwaysAuthorization()
        default:
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        guard !running else { return }
        running = true

        for region in GeoConfig.regions {
            let clRegion = CLCircularRegion(center: region.center,
                                            radius: region.radius,
                                            identifier: region.id)
            clRegion.notifyOnEntry = true
            clRegion.notifyOnExit = true
            manager.startMonitoring(for: clRegion)
            // 起動時点で既にリージョン内にいる場合を捉えるため、初期状態を要求する。
            manager.requestState(for: clRegion)
        }

        if #available(iOS 9.0, *),
           manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.startUpdatingLocation()

        ProbeRecorder.shared.record(type: "probe_started", payload: [
            "monitored_regions": GeoConfig.regions.map { $0.id },
            "authorization": authorizationString(),
        ])
    }

    func stop() {
        guard running else { return }
        running = false

        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        manager.stopUpdatingLocation()

        // 停止後にタイマーだけが生き残ると、計測外の `stop_resolved` が記録されてしまう。
        resolutionTimer?.invalidate()
        resolutionTimer = nil
        resolutionStartedAt = nil

        ProbeRecorder.shared.record(type: "probe_stopped")
    }

    func status() -> [String: Any] {
        let recorderStatus = ProbeRecorder.shared.status()
        var result: [String: Any] = [
            "running": running,
            "authorization": authorizationString(),
            "monitored_count": manager.monitoredRegions.count,
            "event_count": recorderStatus.count,
            "file_path": recorderStatus.filePath,
            "distances": latestDistances,
            "resolving": resolutionStartedAt != nil,
        ]
        if let location = latestLocation {
            result["accuracy"] = location.horizontalAccuracy
            result["speed"] = location.speed
        }
        if let latest = recorderStatus.latest {
            result["latest_type"] = latest["type"]
            result["latest_at"] = latest["occurred_at"]
        }
        return result
    }

    /// 実測時に人手で「実際に起きたこと」を記録するためのマーカー。
    ///
    /// 検知遅延の検証には、真の乗車時刻・発車時刻が必要になる。GPS からは
    /// 「バスに乗った瞬間」を判定できないため、これは人が押すしかない。
    func addMarker(label: String) {
        ProbeRecorder.shared.record(type: "probe_marker", payload: [
            "label": label,
            "distances": latestDistances,
            "accuracy": latestLocation?.horizontalAccuracy ?? -1,
        ])
    }

    // MARK: - のりば判別 (設計書 3.2)

    private func startResolution() {
        resolutionStartedAt = Date()
        resolutionAttempts = 0
        lastAttemptAt = nil

        // 打ち切りを測位の到来に依存させない。判定を `didUpdateLocations` の中だけで行うと、
        // 位置更新が途絶えている間は経過時間の評価そのものが走らず、3.2 の60秒上限を超える
        // (実測で 228 秒かかった)。判別が要る場面はバス停で静止している時なので実害がある。
        //
        // CLLocationManager のデリゲートはこのクラスを生成したスレッド (main) で呼ばれるため、
        // ここで張るタイマーは main の run loop に載る。
        resolutionTimer?.invalidate()
        resolutionTimer = Timer.scheduledTimer(withTimeInterval: GeoConfig.resolutionMaxDuration,
                                               repeats: false) { [weak self] _ in
            guard let self else { return }
            self.finishResolution(with: self.latestLocation)
        }
    }

    /// のりば2点との距離。設計書 3.2 の判別はこの2値だけで行う。
    private struct StopDistances {
        let a: CLLocationDistance
        let b: CLLocationDistance
        let idA: String
        let idB: String

        /// 差がしきい値以上なら近い方に確定する。未満なら判別しない。
        var resolved: String? {
            guard abs(a - b) >= GeoConfig.resolutionThresholdMeters else { return nil }
            return a < b ? idA : idB
        }
    }

    private func stopDistances(for location: CLLocation?) -> StopDistances? {
        guard let location,
              let pointA = GeoConfig.stopPoint(id: "campus_hachioji_bound"),
              let pointB = GeoConfig.stopPoint(id: "campus_minamino_bound") else { return nil }
        return StopDistances(a: location.distance(from: GeoConfig.location(of: pointA.center)),
                             b: location.distance(from: GeoConfig.location(of: pointB.center)),
                             idA: pointA.id, idB: pointB.id)
    }

    /// 測位が届くたびに呼ばれる。**確定できた場合のみ**終了させる。
    /// 確定できないまま時間切れになった場合は `startResolution` が張ったタイマーが打ち切る。
    private func tryResolve(with location: CLLocation) {
        guard resolutionStartedAt != nil else { return }

        // 再測位は10秒間隔 (設計書 3.2)
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < GeoConfig.resolutionRetryInterval {
            return
        }

        resolutionAttempts += 1
        lastAttemptAt = Date()

        guard stopDistances(for: location)?.resolved != nil else {
            return  // まだ猶予がある。次のサンプルで再試行
        }

        finishResolution(with: location)
    }

    /// 判別の終了。確定・打ち切りのいずれもここを通り、`stop_resolved` を1件だけ記録する。
    ///
    /// 打ち切り時点でも、最後の測位で距離差がしきい値を超えていれば確定させる。判別できなければ
    /// `pending` とし、そのセッションは統計から除外されるが生データは残る (不変条件8)。
    private func finishResolution(with location: CLLocation?) {
        guard let startedAt = resolutionStartedAt else { return }
        resolutionStartedAt = nil
        resolutionTimer?.invalidate()
        resolutionTimer = nil

        let distances = stopDistances(for: location)
        let resolved = distances?.resolved

        var payload: [String: Any] = [
            "resolved": resolved ?? "pending",
            "accuracy": location?.horizontalAccuracy ?? -1,
            "attempts": resolutionAttempts,
            "elapsed_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
        ]
        // 測位が一度も届かないまま打ち切られた場合、距離は観測されていない。
        // 0 を入れると「2点が等距離だった」と読めてしまうのでキーごと落とす。
        if let distances {
            payload["d_a"] = distances.a
            payload["d_b"] = distances.b
        }

        ProbeRecorder.shared.record(
            type: "stop_resolved",
            regionId: GeoConfig.campusAreaId,
            stopId: resolved ?? "pending",
            payload: payload
        )
    }

    // MARK: - 補助

    private func updateDistances(from location: CLLocation) {
        var distances: [String: Double] = [:]
        for region in GeoConfig.regions {
            distances[region.id] = location.distance(from: GeoConfig.location(of: region.center))
        }
        for point in GeoConfig.stopPoints {
            distances[point.id] = location.distance(from: GeoConfig.location(of: point.center))
        }
        latestDistances = distances
    }

    private func authorizationString() -> String {
        switch manager.authorizationStatus {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationProbe: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        ProbeRecorder.shared.record(type: "region_enter", regionId: region.identifier, payload: [
            "accuracy": latestLocation?.horizontalAccuracy ?? -1,
            "distances": latestDistances,
        ])

        if region.identifier == GeoConfig.campusAreaId {
            startResolution()
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        ProbeRecorder.shared.record(type: "region_exit", regionId: region.identifier, payload: [
            "accuracy": latestLocation?.horizontalAccuracy ?? -1,
            "distances": latestDistances,
        ])
    }

    /// 起動時の初期状態。既にリージョン内にいるかどうかを知るために使う。
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        let stateName: String
        switch state {
        case .inside: stateName = "inside"
        case .outside: stateName = "outside"
        case .unknown: stateName = "unknown"
        @unknown default: stateName = "unknown"
        }
        ProbeRecorder.shared.record(type: "region_state", regionId: region.identifier, payload: [
            "state": stateName,
        ])
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            latestLocation = location
            updateDistances(from: location)

            ProbeRecorder.shared.record(
                type: "motion_sample",
                payload: [
                    "lat": location.coordinate.latitude,
                    "lon": location.coordinate.longitude,
                    "accuracy": location.horizontalAccuracy,
                    "speed": location.speed,
                    "heading": location.course,
                    "context": "probe_continuous",
                    "distances": latestDistances,
                ],
                // 測位の実際の取得時刻。受信時刻ではない (不変条件3)
                occurredAt: location.timestamp
            )

            tryResolve(with: location)
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        ProbeRecorder.shared.record(type: "probe_error", regionId: region?.identifier, payload: [
            "scope": "monitoring",
            "message": error.localizedDescription,
        ])
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        ProbeRecorder.shared.record(type: "probe_error", payload: [
            "scope": "location",
            "message": error.localizedDescription,
        ])
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        ProbeRecorder.shared.record(type: "authorization_changed", payload: [
            "authorization": authorizationString(),
        ])
        if running, manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
    }
}
