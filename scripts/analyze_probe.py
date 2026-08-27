#!/usr/bin/env python3
"""実測プロトタイプ (設計書 11章) が記録した JSONL を解析する。

検知遅延は次のように求める。

    リージョン監視 → region_enter / region_exit の発火時刻          = 検知時刻
    高精度測位     → 中心からの距離が半径150mを跨いだ時刻 (線形補間)  = 真の通過時刻
                                                       差 = 検知遅延

**通過の判定は端末では行っていない** (不変条件2)。端末は距離を観測値として記録するだけで、
跨いだ時刻の算出はこのスクリプトが担う。

使い方:
    python3 analyze_probe.py probe-2026-08-11.jsonl
    python3 analyze_probe.py 端末A.jsonl 端末B.jsonl    # 2端末の突合まで行う
"""

import json
import statistics
import sys
from datetime import datetime, timedelta

# 設計書 3.1。本来は GET /v1/config 由来だが、解析側では定数として持つ。
REGION_RADIUS_M = 150.0
REGION_IDS = ("campus_area", "st_hachioji", "st_minamino")

# 測位精度がこれより悪いサンプルは通過判定に使わない。ノイズによる偽の跨ぎを避けるため。
MAX_ACCURACY_M = 50.0

# 2端末の同一便とみなす時間差の上限。
PAIRING_WINDOW = timedelta(minutes=10)


def parse_time(value):
    return datetime.fromisoformat(value)


def load(path):
    events = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"  [警告] 壊れた行を読み飛ばしました: {path}")
    events.sort(key=lambda e: e["occurred_at"])
    return events


def crossings(events, region_id):
    """距離が半径を跨いだ時刻を線形補間で求める。

    戻り値: [(時刻, 'in'|'out'), ...]
    """
    samples = []
    for e in events:
        if e.get("type") != "motion_sample":
            continue
        payload = e.get("payload") or {}
        accuracy = payload.get("accuracy")
        distance = (payload.get("distances") or {}).get(region_id)
        if distance is None:
            continue
        if accuracy is None or accuracy < 0 or accuracy > MAX_ACCURACY_M:
            continue
        samples.append((parse_time(e["occurred_at"]), float(distance)))

    result = []
    for (t0, d0), (t1, d1) in zip(samples, samples[1:]):
        inward = d0 >= REGION_RADIUS_M > d1
        outward = d0 < REGION_RADIUS_M <= d1
        if not (inward or outward):
            continue
        span = d1 - d0
        ratio = 0.0 if span == 0 else (REGION_RADIUS_M - d0) / span
        crossed_at = t0 + (t1 - t0) * ratio
        result.append((crossed_at, "in" if inward else "out"))
    return result


def detection_delays(events):
    """検知イベントごとに、直前の真の通過時刻との差を求める。"""
    rows = []
    for region_id in REGION_IDS:
        crossed = crossings(events, region_id)
        for e in events:
            if e.get("type") not in ("region_enter", "region_exit"):
                continue
            if e.get("region_id") != region_id:
                continue

            detected_at = parse_time(e["occurred_at"])
            want = "in" if e["type"] == "region_enter" else "out"

            # 検知は真の通過より後に起きる。直前の同方向の跨ぎを対応付ける。
            candidates = [t for t, d in crossed if d == want and t <= detected_at]
            truth = max(candidates) if candidates else None

            rows.append({
                "region": region_id,
                "type": e["type"],
                "detected_at": detected_at,
                "truth_at": truth,
                "delay_s": (detected_at - truth).total_seconds() if truth else None,
                "accuracy": (e.get("payload") or {}).get("accuracy"),
            })
    rows.sort(key=lambda r: r["detected_at"])
    return rows


def report_delays(rows):
    print("\n=== 検知遅延 ===")
    if not rows:
        print("  リージョンイベントがありません")
        return

    print(f"  {'時刻':<13}{'リージョン':<16}{'種別':<14}{'遅延':>10}  精度")
    for r in rows:
        delay = f"{r['delay_s']:.1f} 秒" if r["delay_s"] is not None else "基準なし"
        accuracy = f"{r['accuracy']:.0f} m" if isinstance(r["accuracy"], (int, float)) and r["accuracy"] >= 0 else "—"
        timestamp = f"{r['detected_at']:%H:%M:%S.%f}"[:12]
        print(f"  {timestamp:<13}{r['region']:<16}{r['type']:<14}{delay:>10}  {accuracy}")

    for kind in ("region_enter", "region_exit"):
        values = [r["delay_s"] for r in rows if r["type"] == kind and r["delay_s"] is not None]
        if not values:
            continue
        print(f"\n  {kind}: n={len(values)}  "
              f"中央値 {statistics.median(values):.1f}秒  "
              f"最小 {min(values):.1f}秒  最大 {max(values):.1f}秒")

    enters = [r["delay_s"] for r in rows if r["type"] == "region_enter" and r["delay_s"] is not None]
    exits = [r["delay_s"] for r in rows if r["type"] == "region_exit" and r["delay_s"] is not None]
    if enters and exits:
        print(f"\n  → enter と exit の中央値の比: "
              f"{statistics.median(exits) / statistics.median(enters):.1f} 倍")
        print("     設計書 5.2.2 は enter のばらつきが exit より桁で小さいことを前提としている。")


def report_resolution(events):
    rows = [e for e in events if e.get("type") == "stop_resolved"]
    if not rows:
        return
    print("\n=== のりば判別 (設計書 3.2) ===")
    pending = 0
    for e in rows:
        p = e.get("payload") or {}
        resolved = p.get("resolved")
        if resolved == "pending":
            pending += 1
        # 測位が一度も届かないまま打ち切られた場合、d_a / d_b は記録されない。
        # 0m と表示すると「2点が等距離だった」と読めてしまうので区別する。
        if "d_a" in p and "d_b" in p:
            diff = f"|d_a-d_b|={abs(float(p['d_a']) - float(p['d_b'])):6.1f}m"
        else:
            diff = "|d_a-d_b|=   測位なし"
        print(f"  {parse_time(e['occurred_at']):%H:%M:%S}  {resolved:<24}"
              f"{diff}  試行{p.get('attempts')}回  "
              f"{p.get('elapsed_ms', 0) / 1000:.1f}秒")
    print(f"\n  pending 率: {pending}/{len(rows)} ({100 * pending / len(rows):.0f}%)")
    print("  → 未決事項#3 (35m しきい値) の較正データ")


def report_markers(events):
    rows = [e for e in events if e.get("type") == "probe_marker"]
    if not rows:
        return
    print("\n=== マーカー (人手記録) ===")
    for e in rows:
        label = (e.get("payload") or {}).get("label")
        print(f"  {parse_time(e['occurred_at']):%H:%M:%S}  {label}")


def report_pairing(named_events):
    """2端末の region_enter 発火時刻差。層1 (設計書 5.2.3) の成否を直接決める数値。"""
    if len(named_events) < 2:
        return
    (name_a, events_a), (name_b, events_b) = named_events[0], named_events[1]

    print("\n=== 2端末の突合 ===")
    print(f"  A: {name_a}\n  B: {name_b}")

    diffs = []
    for kind in ("region_enter", "region_exit"):
        a_events = [e for e in events_a if e.get("type") == kind]
        b_events = [e for e in events_b if e.get("type") == kind]
        for ea in a_events:
            ta = parse_time(ea["occurred_at"])
            same = [eb for eb in b_events
                    if eb.get("region_id") == ea.get("region_id")
                    and abs(parse_time(eb["occurred_at"]) - ta) <= PAIRING_WINDOW]
            if not same:
                continue
            eb = min(same, key=lambda x: abs(parse_time(x["occurred_at"]) - ta))
            delta = (parse_time(eb["occurred_at"]) - ta).total_seconds()
            print(f"  {ta:%H:%M:%S}  {ea['region_id']:<16}{kind:<14}差 {delta:+.1f} 秒")
            if kind == "region_enter":
                diffs.append(abs(delta))

    if diffs:
        median = statistics.median(diffs)
        print(f"\n  region_enter の時刻差: n={len(diffs)}  中央値 {median:.1f}秒  最大 {max(diffs):.1f}秒")
        print("\n  【判定】")
        if max(diffs) < 60:
            print("  数十秒に収まっている → 設計書 5.2 の層1は成立する見込み。")
        elif max(diffs) < 120:
            print("  1〜2分。発車間隔が詰まる混雑時は際どい。サンプルを増やして再確認すること。")
        else:
            print("  数分に及ぶ → 着地点も chaining する。設計書 5.2 の再設計が必要 (未決事項#7)。")


def main():
    paths = sys.argv[1:]
    if not paths:
        print(__doc__)
        sys.exit(1)

    named_events = []
    for path in paths:
        events = load(path)
        named_events.append((path, events))
        print(f"\n{'=' * 60}\n{path}  ({len(events)} イベント)\n{'=' * 60}")
        counts = {}
        for e in events:
            counts[e.get("type")] = counts.get(e.get("type"), 0) + 1
        print("  " + "  ".join(f"{k}:{v}" for k, v in sorted(counts.items())))

        report_delays(detection_delays(events))
        report_resolution(events)
        report_markers(events)

    report_pairing(named_events)


if __name__ == "__main__":
    main()
