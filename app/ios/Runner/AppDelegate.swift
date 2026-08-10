import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerProbeChannel(engineBridge)
  }

  /// 設計書 4.7 の MethodChannel。
  ///
  /// **イベントはこのチャネルを流れない** (不変条件10)。記録・キューイングはネイティブ層で完結し、
  /// Dart は設定の投入と状態の取得のみを行う。`addMarker` は実測プロトタイプ専用であり、
  /// 本実装では `enqueueBoardingHint` に相当する。
  private func registerProbeChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BusWaitProbe") else {
      return
    }

    let channel = FlutterMethodChannel(name: "jp.ac.teu.buswait/geo",
                                       binaryMessenger: registrar.messenger())

    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]

      switch call.method {
      case "requestPermission":
        let level = args["level"] as? String ?? "whenInUse"
        LocationProbe.shared.requestPermission(level: level)
        result(nil)

      case "start":
        LocationProbe.shared.start()
        result(nil)

      case "stop":
        LocationProbe.shared.stop()
        result(nil)

      case "getStatus":
        result(LocationProbe.shared.status())

      case "getRecentEvents":
        let limit = args["limit"] as? Int ?? 50
        result(ProbeRecorder.shared.recentEvents(limit: limit))

      case "addMarker":
        let label = args["label"] as? String ?? "unknown"
        LocationProbe.shared.addMarker(label: label)
        result(nil)

      case "getExportPath":
        result(ProbeRecorder.shared.exportDirectoryPath())

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
