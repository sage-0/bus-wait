import Foundation

/// イベントの記録先。
///
/// 実測プロトタイプではサーバーを持たないため、端末内 Documents に JSON Lines として追記する。
/// **スキーマは設計書 6.2 の `POST /v1/events` に準拠する** — 本実装のサーバーでそのまま解析できる
/// ようにするため (設計書 11.3)。
///
/// 判定は一切行わない (不変条件2)。距離等の派生値は `payload` に持つが、これは観測値であって
/// 判定結果ではない。唯一の例外は `stop_resolved` で、これは設計書 3.2 が端末側の責務と定めている。
final class ProbeRecorder {

    static let shared = ProbeRecorder()

    private let queue = DispatchQueue(label: "jp.ac.teu.buswait.recorder")
    private let formatter: ISO8601DateFormatter
    private var recent: [[String: Any]] = []
    private var totalCount = 0

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // 設計書 6.2 はオフセット付き ISO 8601 を要求する。UTC の "Z" ではなく端末のタイムゾーンで出す。
        formatter.timeZone = TimeZone.current
    }

    // MARK: - 記録

    /// - Parameter occurredAt: **イベント発生時刻**。記録時刻ではない (不変条件3)。
    func record(type: String,
                regionId: String? = nil,
                stopId: String? = nil,
                payload: [String: Any] = [:],
                occurredAt: Date = Date()) {

        var event: [String: Any] = [
            "event_id": UUID().uuidString,
            "type": type,
            "occurred_at": formatter.string(from: occurredAt),
            "recorded_at": formatter.string(from: Date()),
            "payload": payload,
        ]
        event["region_id"] = regionId ?? NSNull()
        event["stop_id"] = stopId ?? NSNull()

        queue.async { [weak self] in
            guard let self else { return }
            self.append(event)
            self.totalCount += 1
            self.recent.insert(event, at: 0)
            if self.recent.count > 200 {
                self.recent.removeLast(self.recent.count - 200)
            }
        }
    }

    // MARK: - 参照

    func status() -> (count: Int, latest: [String: Any]?, filePath: String) {
        queue.sync {
            (totalCount, recent.first, currentFileURL().path)
        }
    }

    func recentEvents(limit: Int) -> [[String: Any]] {
        queue.sync { Array(recent.prefix(limit)) }
    }

    /// Files アプリから取り出せるよう Documents 直下に置く。
    func exportDirectoryPath() -> String {
        documentsURL().path
    }

    // MARK: - 内部

    private func append(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return }

        // 追記。新しい throws 版 API は iOS 13.4 以降のため、deployment target に合わせて旧 API を使う。
        let url = currentFileURL()
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(lineData)
        } else {
            // ファイルがまだ存在しない場合 (その日の最初のイベント)
            try? lineData.write(to: url, options: .atomic)
        }
    }

    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 日付ごとにファイルを分ける。測定日単位で取り出しやすくするため。
    private func currentFileURL() -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        return documentsURL().appendingPathComponent("probe-\(df.string(from: Date())).jsonl")
    }
}
