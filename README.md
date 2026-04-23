# Bag — Bitcoin Portfolio Monitor

A Bitcoin-only price tracker and net worth dashboard for Android, with iOS coming soon. Enter how much BTC you hold, pick up to three fiat currencies, and see your portfolio value update in real time alongside a price chart and DCA tracker.

No accounts. No analytics. No ads. Your holdings never leave your device.

---

## Features

**Free, forever:**
- Live BTC price with 24h change (CoinGecko primary, mempool.space fallback)
- Net worth in up to 3 selectable fiat currencies
- Historical price charts (1D / 1W / 1M / 1Y / ALL)
- DCA tracker — log purchases, track average cost and unrealised P&L
- Home screen widget with price and net worth
- Sats / BTC display toggle

**Pro — one-time purchase ($7.99):**
- Watch-only zpub wallet tracking (BIP84 / P2WPKH)
- Tor routing via Orbot — all wallet queries go through SOCKS5
- Custom Esplora server (auto-detects API path)
- Multi-wallet portfolio with per-wallet balances
- Bitcoin Health Check — cross-wallet UTXO privacy scoring
- Sentinel always-on monitoring — mempool alerts for incoming/outgoing transactions
- Mempool fee estimates with configurable alerts

---

## Privacy

- BTC holdings are stored locally in SharedPreferences. They are never transmitted anywhere.
- zpub keys are stored in FlutterSecureStorage (hardware-backed EncryptedSharedPreferences on supporting devices). Only derived addresses reach the explorer.
- No tracking SDKs, no crash reporters, no analytics of any kind.
- With Tor enabled, all network requests (price, wallet scans, fee estimates) route through Orbot. There is no silent clearnet fallback.

---

## Building

**Requirements:** Flutter SDK >= 3.7.0, Android SDK, NDK 27.0.12077973

```bash
flutter pub get
flutter run                                                          # debug, direct flavor
flutter build apk --release --dart-define=FLAVOR=direct             # release APK (website / F-Droid)
flutter build appbundle --release --dart-define=FLAVOR=playstore    # AAB for Google Play
dart run build_runner build --delete-conflicting-outputs            # regenerate Riverpod code
flutter analyze
flutter test
```

There are two flavors:

| Flavor | Use | Pro unlock |
|--------|-----|------------|
| `direct` | Website, F-Droid, sideload | Ed25519 license token via App Link |
| `playstore` | Google Play | `in_app_purchase` |

Release builds require a signing keystore. See the CI workflow (`.github/workflows/release.yml`) for the full signing and GPG-verification steps.

**iOS** support is in progress. The core Dart code is cross-platform; the remaining work is iOS-specific: home screen widget (WidgetKit), Sentinel background service (BGTaskScheduler), and App Store distribution. Once ready it will ship as a separate flavor alongside the existing Android builds.

---

## Architecture

Feature-based Flutter structure. State management via Riverpod 2.x, navigation via GoRouter with a `StatefulShellRoute` bottom nav (Home / DCA / Settings).

```
lib/
  core/          — constants, theme, shared utilities
  features/      — screen-level widgets (home, dca, settings, onboarding, splash)
  models/        — plain Dart data classes (no Hive TypeAdapters)
  providers/     — Riverpod notifiers and providers
  services/      — API clients, wallet engine, Sentinel background service
  widgets/       — reusable UI components
```

Local persistence: Hive (JSON strings) for price cache and DCA entries; SharedPreferences for settings and wallet metadata; FlutterSecureStorage for zpub keys.

---

## Pro Unlock

The `direct` flavor uses a self-hosted backend (`bitbag.app`) for purchase and unlock:

1. User visits `bitbag.app/pro` and pays via OpenNode (Lightning or on-chain)
2. The backend signs an Ed25519 token bound to the order ID
3. The token is delivered as an Android App Link (`https://bitbag.app/unlock?token=...`)
4. The app verifies the signature against an embedded 32-byte public key and stores the result in FlutterSecureStorage

Flipping the SharedPreferences boolean alone does nothing — the token is re-verified against the embedded key on every cold start. The backend is proprietary and not part of this repository.

---

## Contributing

Bug reports and pull requests are welcome. A few things worth knowing before diving in:

- This is a Bitcoin-only app. Altcoin support will not be added.
- Avoid introducing analytics, crash reporters, or any third-party SDKs that phone home.
- Run `flutter analyze` and `dart format lib/` before opening a PR.
- For significant changes, open an issue first to discuss the approach.

---

## License

[![GPL-3.0-only](https://img.shields.io/badge/License-GPL--3.0--only-blue.svg)](https://spdx.org/licenses/GPL-3.0-only.html)

This repository contains the open-source app code — the build distributed via direct download and F-Droid. The Pro unlock backend and Google Play release pipeline are proprietary and not included here.
