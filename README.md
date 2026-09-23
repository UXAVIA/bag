# Bag — Bitcoin Portfolio Monitor

Watch-only Bitcoin tracker for Android and iOS: xpub / zpub, output descriptors and multisig (Bitkey 2-of-3, Sparrow, Nunchuk exports), net worth in up to three currencies, a DCA log and a home-screen widget — over Tor if you want. Enter how much BTC you hold, or paste a watch-only key, and see your portfolio update in real time alongside a price chart.

No accounts. No analytics. No ads. Your holdings never leave your device.

If Bag is useful to you, a rating on [Google Play](https://play.google.com/store/apps/details?id=app.bitbag) or the [App Store](https://apps.apple.com/us/app/bag-bitcoin-portfolio-monitor/id6761279862) is the single most helpful thing you can do for the project — the stores rank by it, and the app never asks with a pop-up more than once.

Guides: [Bitkey watch-only](https://bitbag.app/bitkey-watch-only/) · [xpub balance checker](https://bitbag.app/xpub-balance-checker/) · [multisig watch-only](https://bitbag.app/multisig-watch-only/) · [Android widget](https://bitbag.app/bitcoin-widget-android/) · [DCA tracker](https://bitbag.app/bitcoin-dca-tracker/)

---

## Features

**Free, forever:**
- Live BTC price with 24h change (CoinGecko primary, mempool.space fallback)
- Net worth in up to 3 selectable fiat currencies
- Historical price charts (1D / 1W / 1M / 1Y / 5Y / ALL)
- DCA tracker — log purchases, track average cost and unrealised P&L
- Home screen widget with price and net worth
- Sats / BTC display toggle

**Pro — one-time purchase ($7.99):**
- Watch-only wallet tracking from a `zpub` (BIP84 / P2WPKH) or an output descriptor — including multisig such as Bitkey's 2-of-3
- Manually-tracked balances for coins held elsewhere (e.g. an exchange), summed into net worth alongside your wallets
- Tor routing via Orbot — all wallet queries go through SOCKS5
- Custom Esplora server (auto-detects API path)
- Multi-wallet portfolio with per-wallet balances
- Bitcoin Health Check — cross-wallet UTXO privacy scoring
- Sentinel always-on monitoring — mempool alerts for incoming/outgoing transactions
- Mempool fee estimates with configurable alerts

---

## Privacy

- Everything financial is encrypted at rest. Wallet keys and descriptors, per-wallet balances, your total holding, the DCA purchase log, health-check results and your custom node address all live in FlutterSecureStorage (Android Keystore / iOS Keychain) or an AES-256 Hive box — never in plaintext app storage. None of it is ever transmitted anywhere.
- Only derived addresses reach the block explorer. The zpub or descriptor itself never leaves the device.
- No tracking SDKs, no crash reporters, no analytics of any kind.
- With Tor enabled, all network requests (price, charts, wallet scans, fee estimates) route through Orbot. There is no silent clearnet fallback: on Android the SOCKS5 client fails closed, and on iOS — where Orbot is a system VPN with no proxy to configure — every request is gated on an explicit Tor reachability check.

---

## Building

**Requirements:** Flutter SDK as pinned in [`.flutter-version`](.flutter-version) (Dart >= 3.10), Android SDK, NDK 27.0.12077973

```bash
flutter pub get
flutter run                                                          # debug, direct flavor
flutter build apk --release --dart-define=FLAVOR=direct             # release APK (website / F-Droid)
flutter build appbundle --release --dart-define=FLAVOR=store         # AAB for Google Play
flutter build ipa --release --dart-define=FLAVOR=store               # IPA for the App Store
flutter analyze
flutter test
```

There are two flavors:

| Flavor | Use | Pro unlock |
|--------|-----|------------|
| `direct` | Website, F-Droid, sideload | Ed25519 license token via App Link |
| `store` | Google Play + App Store | `in_app_purchase` |

Release builds require a signing keystore, supplied to Gradle through environment variables — no credentials live in this repository.

Sentinel is Android-only: it relies on a long-running foreground service, which iOS does not permit. It is hidden from the UI on iOS.

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

Local persistence splits along a privacy line. FlutterSecureStorage holds everything financial — wallet keys and descriptors, wallet metadata and balances, the total holding, health-check results, Sentinel state and the custom node URL. DCA entries live in an AES-256 encrypted Hive box whose key is itself in secure storage. Plain SharedPreferences holds only non-sensitive settings: theme, display currencies, sats mode, alert targets and the explorer preset. The unencrypted Hive box caches public market data only.

Because the sensitive values are encrypted, they cannot be read synchronously — `main()` decrypts them before `runApp` and injects them as Riverpod overrides.

---

## Pro Unlock

The `direct` flavor uses a self-hosted backend (`bitbag.app`) for purchase and unlock:

1. User visits `bitbag.app/pro` and pays via OpenNode (Lightning or on-chain)
2. The backend signs an Ed25519 token bound to the order ID
3. The token is delivered as an App Link (`https://bitbag.app/unlock?token=...`)
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

GNU General Public License v3.0. See [LICENSE](LICENSE) for the full text.

This repository contains the open-source app code — the build distributed via direct download and F-Droid. The Pro unlock backend and Google Play release pipeline are proprietary and not included here.
