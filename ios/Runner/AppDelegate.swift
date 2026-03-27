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

    // No-op stubs for the Android-only app.bitbag/widget MethodChannel.
    // Prevents MissingPluginException if any Dart code reaches these paths on iOS.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BagWidgetChannel") else { return }
    let channel = FlutterMethodChannel(
      name: "app.bitbag/widget",
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getSdkVersion": result(0)
      case "requestPinWidget": result(false)
      case "setSecureMode": result(nil as Any?)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}
