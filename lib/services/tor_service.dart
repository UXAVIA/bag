// Tor availability and SOCKS port.
//
// Tor runs inside the app on both platforms ([EmbeddedTorService]), one
// client per process shared by every isolate ([TorHost]), and exposes its
// own local SOCKS5 port, which changes after every restart. Availability is
// the client's state as this isolate sees it, read synchronously; nothing
// goes on the network.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../models/network_route.dart';
import 'embedded_tor_service.dart';
import 'network/route_gate.dart';
import 'tor_host.dart';

class TorService {
  TorService._();

  /// Test seam: forces the iOS (true) or Android (false) branch on the host
  /// VM. Null means [Platform.isIOS]. Reset it in tearDown.
  @visibleForTesting
  static bool? debugIsIOS;

  /// Whether this is iOS. Tor behaves the same on both platforms; this only
  /// picks iOS-only widget code and the per-platform migration pref.
  static bool get isIOS => debugIsIOS ?? Platform.isIOS;

  /// Makes the embedded client follow the selected [route]. UI isolate
  /// only: the UI's route is the one [TorHost] obeys. [TorRoute] starts it
  /// (or leases it from the isolate already running it); any other route
  /// stops it, in whichever isolate runs it (R-A2b), then sweeps whatever
  /// client the process still runs ([TorHost.routeChanged]). Neither is
  /// awaited — a bootstrap can take tens of seconds, and a native stop can
  /// hang — so a route change never waits on the client. Waiting isn't
  /// needed for safety: [EmbeddedTorService.stop] moves the state to `off`
  /// and the port to -1 before it returns its future, so every Tor request
  /// is refused at once, and the service serialises native start and stop
  /// itself (a later start waits for a pending stop; there is never more
  /// than one native start). Errors are logged, never thrown: the route
  /// change applies regardless, and `main()` calls this before `runApp`.
  static void followRoute(NetworkRoute route) {
    try {
      TorHost.routeChanged(tor: route is TorRoute);
      if (route is TorRoute) {
        // The outcome lands in EmbeddedTorService.state; this never throws.
        unawaited(EmbeddedTorService.ensureStarted());
      } else {
        unawaited(EmbeddedTorService.stop().catchError(_logEmbeddedError));
      }
    } catch (e) {
      _logEmbeddedError(e);
    }
  }

  static void _logEmbeddedError(Object e) {
    if (kDebugMode) debugPrint('[TorService] embedded Tor: $e');
  }

  /// This platform's migration pref: [AppConstants.keyIosTorMigrated] or
  /// [AppConstants.keyAndroidTorMigrated]. Both take the same values.
  static String get _migratedKey => isIOS
      ? AppConstants.keyIosTorMigrated
      : AppConstants.keyAndroidTorMigrated;

  /// At startup, before the UI (ruling R8): records once whether this
  /// install had Tor on before built-in Tor replaced the separate Tor app.
  /// Writes this platform's migration pref only when it is absent — 'show'
  /// if `use_tor` is already true, otherwise 'none' — and never re-evaluates
  /// it, so a user who turns Tor on later never sees the hint.
  static Future<void> recordOrbotMigration(SharedPreferences prefs) async {
    final key = _migratedKey;
    if (prefs.containsKey(key)) return;
    final hadTor = prefs.getBool(AppConstants.keyUseTor) ?? false;
    await prefs.setString(
      key,
      hadTor
          ? AppConstants.torMigratedShow
          : AppConstants.torMigratedNone,
    );
  }

  /// Whether the one-time migration hint is due on this platform.
  static bool showOrbotMigrationHint(SharedPreferences prefs) =>
      prefs.getString(_migratedKey) == AppConstants.torMigratedShow;

  /// The user dismissed the hint: it never comes back.
  static Future<void> dismissOrbotMigrationHint(SharedPreferences prefs) =>
      prefs.setString(_migratedKey, AppConstants.torMigratedDismissed);

  /// Whether Tor can carry traffic right now: only while the embedded client
  /// is bootstrapped and publishes a port. Starting, failed and off are all
  /// unavailable.
  static Future<RouteStatus> probe() async =>
      EmbeddedTorService.carriesTraffic
          ? RouteStatus.available
          : RouteStatus.unavailable;
}
