import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 実測プロトタイプ (設計書 11章) の UI。
///
/// Dart 側の責務は権限フロー・状態表示・マーカー入力のみ (不変条件10)。
/// イベントの記録と保存はネイティブ層で完結しており、このチャネルを流れない。
void main() {
  runApp(const ProbeApp());
}

const _channel = MethodChannel('jp.ac.teu.buswait/geo');

/// 実測時に人手で記録するマーカー。GPS からは判定できない「実際に起きたこと」の基準になる。
const _markers = <String, String>{
  'bus_arrived': 'バス到着',
  'boarded': '乗車した',
  'departed': 'バス発車',
  'alighted': '降車した',
};

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bus Wait Probe',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.teal)),
      home: const ProbeHomePage(),
    );
  }
}

class ProbeHomePage extends StatefulWidget {
  const ProbeHomePage({super.key});

  @override
  State<ProbeHomePage> createState() => _ProbeHomePageState();
}

class _ProbeHomePageState extends State<ProbeHomePage> {
  Map<String, dynamic> _status = {};
  List<dynamic> _events = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      final events = await _channel.invokeListMethod<dynamic>(
        'getRecentEvents',
        {'limit': 30},
      );
      if (!mounted) return;
      setState(() {
        _status = status ?? {};
        _events = events ?? [];
      });
    } on PlatformException {
      // プロトタイプでは握りつぶす。状態表示が止まるだけで記録には影響しない。
    }
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$method: ${e.message}')));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final running = _status['running'] == true;
    final distances = (_status['distances'] as Map?)?.cast<String, dynamic>() ?? {};

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bus Wait Probe'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusCard(running),
          const SizedBox(height: 12),
          _controlCard(running),
          const SizedBox(height: 12),
          _markerCard(running),
          const SizedBox(height: 12),
          _distanceCard(distances),
          const SizedBox(height: 12),
          _eventCard(),
        ],
      ),
    );
  }

  Widget _statusCard(bool running) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Row(
              children: [
                Icon(
                  running ? Icons.play_circle : Icons.stop_circle,
                  color: running ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  running ? '計測中' : '停止中',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(),
            _row('権限', '${_status['authorization'] ?? '-'}'),
            _row('監視リージョン', '${_status['monitored_count'] ?? 0} 件'),
            _row('記録イベント', '${_status['event_count'] ?? 0} 件'),
            _row('測位精度', _formatMeters(_status['accuracy'])),
            _row('のりば判別', _status['resolving'] == true ? '実行中' : '—'),
            _row('最終イベント', '${_status['latest_type'] ?? '-'}'),
          ],
        ),
      ),
    );
  }

  Widget _controlCard(bool running) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            // 設計書 4.4: いきなり「常に許可」を求めない
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _invoke('requestPermission', {'level': 'whenInUse'}),
                    child: const Text('使用中のみ許可'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _invoke('requestPermission', {'level': 'always'}),
                    child: const Text('常に許可'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => _invoke(running ? 'stop' : 'start'),
              icon: Icon(running ? Icons.stop : Icons.play_arrow),
              label: Text(running ? '計測を停止' : '計測を開始'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _markerCard(bool running) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Text('マーカー', style: Theme.of(context).textTheme.titleMedium),
            const Text(
              '実際に起きた瞬間に押す。検知遅延の基準になる。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _markers.entries.map((e) {
                return ElevatedButton(
                  onPressed: running ? () => _invoke('addMarker', {'label': e.key}) : null,
                  child: Text(e.value),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _distanceCard(Map<String, dynamic> distances) {
    if (distances.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('測位待ち…'),
        ),
      );
    }
    final keys = distances.keys.toList()..sort();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Text('各地点までの距離', style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            ...keys.map((k) => _row(k, _formatMeters(distances[k]))),
          ],
        ),
      ),
    );
  }

  Widget _eventCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Text('直近のイベント', style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            if (_events.isEmpty)
              const Text('まだありません')
            else
              ..._events.take(30).map((e) {
                final map = (e as Map).cast<String, dynamic>();
                final at = '${map['occurred_at'] ?? ''}';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${at.length >= 19 ? at.substring(11, 23) : at}  '
                    '${map['type']}  ${map['region_id'] ?? ''}',
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: .spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value),
        ],
      ),
    );
  }

  String _formatMeters(dynamic value) {
    if (value is! num || value < 0) return '—';
    return value >= 1000
        ? '${(value / 1000).toStringAsFixed(2)} km'
        : '${value.toStringAsFixed(1)} m';
  }
}
