# 実測プロトタイプ

設計書 (`../docs/design.md`) 11章の測定を行うアプリ。

**目的は 5.2.2 の仮定の検証** — 着地点の `region_enter` のばらつきが、出発側の `region_exit` より
桁で小さいことを確かめる。これが成立しなければ 5.2 の層1は成立せず、再設計が必要になる。

本アプリは捨て実装ではない。4.5 のネイティブ層の最小実装であり、本実装にそのまま引き継ぐ。

## 構成

```
lib/main.dart              計測UI（権限・開始停止・マーカー・距離・イベント一覧）
ios/Runner/
  GeoConfig.swift          リージョン3件とのりば2点（設計書 3.1 / 3.2）
  ProbeRecorder.swift      JSON Lines 書き出し（スキーマは 6.2 準拠）
  LocationProbe.swift      CLLocationManager 一式
  AppDelegate.swift        MethodChannel（4.7 の契約）
../scripts/analyze_probe.py  解析
```

## 初回セットアップ

1. iPhone を USB 接続し、端末側で「このコンピュータを信頼」
2. `open ios/Runner.xcodeproj`
3. Runner ターゲット → **Signing & Capabilities**
   - "Automatically manage signing" にチェック
   - Team に Apple ID を設定（**無料アカウントでよい**。Apple Developer Program は不要）
4. 実機を選んで Run
5. iPhone 側: 設定 → 一般 → VPN とデバイス管理 → デベロッパを信頼

> 無料プロビジョニングでは**署名が7日で切れる**。切れたら再度 Run すればよい。
> 長期の連続測定を行う段階になったら Apple Developer Program ($99/年) を検討する。

以降は `flutter run -d <device-id>` でよい。`flutter devices` で ID を確認する。

### 実測に持ち出す端末には release ビルドを入れる

**debug ビルドはホーム画面から起動できない**（iOS 14 以降の制約。アイコンを叩くと
"debug mode Flutter apps can only be launched from Flutter tooling" と出て止まる）。
`flutter run` に繋いだまま Mac ごとバスに乗るわけにいかないので、測定用は release を入れる。

```bash
flutter build ios --release
ideviceinstaller -u <device-id> install build/ios/iphoneos/Runner.app
```

`flutter run --release` はインストール後の起動処理で失敗することがあるが、上記のように
`ideviceinstaller` で入れれば単独で起動できる。アプリの更新では Documents のデータも
権限の設定も保持される。

## 測定手順

### 準備

- **「常に許可」を与える**（アプリ内のボタン → 設定アプリでの昇格が必要な場合がある）
- **低電力モードをオフにする**。測位が抑制される
- 「計測を開始」を押す

### 乗車中

- **アプリを開いたままにする**。バックグラウンドでも動くよう設定してあるが、確実性を優先する
- 実際に起きた瞬間にマーカーを押す。**これが検知遅延の真値の基準になる**

| マーカー | 押すタイミング |
|---|---|
| バス到着 | バスがバス停に着いた瞬間 |
| 乗車した | 自分がバスに乗り込んだ瞬間 |
| バス発車 | バスが動き出した瞬間 |
| 降車した | 自分がバスを降りた瞬間 |

- 徒歩や自動車での代用は成立しない（速度と経路が異なる）。**実際にバスに乗ること**

### 2端末での測定（最優先）

**同一のバスに2台とも乗せる。** 両方で計測を開始し、同じようにマーカーを押す。

この測定が層1の成否を単独で決める。`region_enter` の発火時刻差が数十秒に収まれば成立、
数分に及べば 5.2 の再設計が必要になる。

## データの回収

`Documents/probe-YYYY-MM-DD.jsonl` に日付ごとに記録される。

iPhone の **ファイル App → 自分の iPhone → Bus Wait** から取り出せる（AirDrop 等でも可）。

### Mac から直接引き抜く

USB 接続していれば端末を触らずに取り出せる。`afcclient` は House arrest を拒否される
（`Permission denied (10)`）ため `pymobiledevice3` を使う。

```bash
pip3 install --break-system-packages pymobiledevice3

# ファイル名の確認
printf 'ls\nexit\n' | python3 -m pymobiledevice3 apps afc --documents jp.ac.teu.busWait

# 取り出し
printf 'pull probe-2026-08-17.jsonl /tmp/probe.jsonl\nexit\n' \
  | python3 -m pymobiledevice3 apps afc --documents jp.ac.teu.busWait
```

## 解析

```bash
python3 ../scripts/analyze_probe.py probe-2026-08-11.jsonl

# 2端末を突合する場合（層1の判定が出る）
python3 ../scripts/analyze_probe.py 端末A.jsonl 端末B.jsonl
```

出力されるもの:

- 検知遅延（`region_enter` / `region_exit` それぞれの中央値・最小・最大）
- **enter と exit の中央値の比** ← 5.2.2 の仮定を直接検証する数字
- 2端末の発火時刻差と、層1が成立するかの判定
- のりば判別の pending 率・試行回数（未決事項#3 の較正データ）

真の通過時刻は、`motion_sample` の距離系列が半径150mを跨いだ点を線形補間して求める。
**この判定は端末では行わない**（不変条件2）。端末は距離を観測値として記録するだけである。

## 既知の制約

- **`motion_sample` はリージョンの外でも緯度経度を1秒間隔で記録する。** 真の通過時刻を距離系列から
  求めるために必要だが（上記「解析」）、これは設計書 9.1 の「大学と最寄り2駅の周辺以外では位置を
  一切記録しない」という利用者への保証と真逆である。本実装では 4.2 の測位ウィンドウ限定に
  置き換わる（不変条件16）。**2端末測定で他人の端末に入れる際は、この点を説明してから同意を得ること**
- 「使用中のみ許可」だと画面ロックで測位が止まる。測定中は必ず「常に許可」にする
- Android 未実装。iOS の測定が回り始めてから着手する
- サーバー送信なし。実測段階ではローカル記録のみ
- 設定はハードコード。本実装では `GET /v1/config` による配信に置き換わる（不変条件11）
