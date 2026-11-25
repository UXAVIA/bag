# Bag — Bitcoin Portfolio Monitor

Watch-only Bitcoin tracker for Android and iOS: xpub / zpub, output descriptors and multisig (Bitkey 2-of-3, Sparrow, Nunchuk exports), net worth in up to three currencies, a DCA log and a home-screen widget — over Tor if you want. Enter how much BTC you hold, or paste a watch-only key, and see your portfolio update in real time alongside a price chart.

No accounts. No analytics. No ads. Your holdings never leave your device.

If Bag is useful to you, a rating on [Google Play](https://play.google.com/store/apps/details?id=app.bitbag) or the [App Store](https://apps.apple.com/us/app/bag-bitcoin-portfolio-monitor/id6761279862) is the single most helpful thing you can do for the project — the stores rank by it, and the app never asks with a pop-up more than once.

Guides: [Bitkey watch-only](https://bitbag.app/bitkey-watch-only/) · [xpub balance checker](https://bitbag.app/xpub-balance-checker/) · [multisig watch-only](https://bitbag.app/multisig-watch-only/) · [Android widget](https://bitbag.app/bitcoin-widget-android/) · [DCA tracker](https://bitbag.app/bitcoin-dca-tracker/)

---

## Features

**Free, forever:**
- Live BTC price with 24h change (Bag's own averaged price feed, with CoinGecko, Coinbase, mempool.space and Bitfinex as fallbacks)
- Net worth in up to 3 selectable fiat currencies
- Historical price charts (1D / 1W / 1M / 1Y / 5Y / ALL)
- DCA tracker — log purchases, track average cost and unrealised P&L
- Home screen widget with price, chart and net worth, refreshed in the background; it shows the route in use (Tor / Proxy / Direct) and when the price was last updated
- Sats / BTC display toggle

**Pro — one-time purchase ($7.99):**
- Watch-only wallet tracking from a `zpub` (BIP84 / P2WPKH) or an output descriptor — including multisig such as Bitkey's 2-of-3
- Manually-tracked balances for coins held elsewhere (e.g. an exchange), summed into net worth alongside your wallets
- Built-in Tor (Arti, compiled into the app) — no Orbot or other app needed
- Custom SOCKS5 / HTTP proxy, as an alternative to Tor
- Custom Esplora server (auto-detects API path)
- Multi-wallet portfolio with per-wallet balances
- Bitcoin Health Check — cross-wallet UTXO privacy scoring
- Sentinel always-on monitoring — mempool alerts for incoming/outgoing transactions
- Network fee estimates from your selected explorer, with configurable alerts

---

## Privacy

- Everything financial is encrypted at rest. Wallet keys and descriptors, per-wallet balances, your total holding, the DCA purchase log, health-check results and your custom node address all live in FlutterSecureStorage (Android Keystore / iOS Keychain) or an AES-256 Hive box — never in plaintext app storage. None of it is ever transmitted anywhere.
- Only derived addresses reach the block explorer. The zpub or descriptor itself never leaves the device.
- No tracking SDKs, no crash reporters, no analytics of any kind.
- With Tor or a custom proxy enabled, every network request (price, charts, wallet scans, fee estimates, background widget refreshes, Sentinel) goes through it, on both platforms. There is no clearnet fallback: if Tor hasn't connected or the proxy is down, requests are refused and the app says so, instead of quietly showing old prices. `.onion` explorers are only reached over Tor or a SOCKS5 proxy, and redirects are never followed.

---

## Building

**Requirements:** Flutter SDK as pinned in [`.flutter-version`](.flutter-version) (Dart >= 3.13.7), Android SDK, NDK 28.2.13676358 (r28c: its 16 KB page default is what Play requires)

Building the app (not `flutter test` or `flutter analyze`) also needs Rust, installed with [rustup](https://rustup.rs): the embedded Tor library (Arti, from the [`tor`](https://github.com/UXAVIA/tor) plugin) is compiled from source during the build, with your `stable` toolchain (release builds use Rust 1.100.0, the plugin's `rust/rust-toolchain`). Add the targets for your platform, `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android` or `aarch64-apple-ios`. The C libraries the crates bundle (AWS-LC, SQLite, xz and Zstandard) are compiled with the NDK's or Xcode's clang, so nothing else needs installing.

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

Feature-based Flutter structure. State management via Riverpod 2.x, navigation via GoRouter with a `StatefulShellRoute` bottom nav (Home / Wallets / DCA / Settings).

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

The third-party software Bag is built with, and its licence notices, are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the app shows the same notices under Settings → About → Open-source licences.

This repository contains the open-source app code — the build distributed via direct download and F-Droid. The Pro unlock backend and Google Play release pipeline are proprietary and not included here.
