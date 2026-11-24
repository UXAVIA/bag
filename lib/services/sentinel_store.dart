/// Edits Sentinel's three encrypted state blobs from outside the service.
///
/// The watch map (`address → {wid, wlabel}`), the seen txids
/// (`txid → {wid, …}`) and the balances (`walletId → sats`) all describe a
/// wallet's on-chain footprint. When the user removes a wallet, its entries
/// go at once instead of lingering until a full scan rebuilds them: the
/// mempool ticks re-read the watch map, so they stop querying the removed
/// wallet's addresses from the next tick on.
///
/// A full scan already running in the Sentinel isolate may still write the
/// removed wallet's addresses back into the watch map once; the next full
/// scan rebuilds the map from the wallet list and drops them for good. Its
/// balance is not written back: every full scan reads the wallet list again
/// just before it writes the balances, and keeps only wallets still stored
/// (net R-3). Seen txids expire after 24 h.
library;

import 'dart:convert';

import '../core/constants/app_constants.dart';
import 'wallet/biometric_storage_service.dart' as bio;

/// The wallet-id field in Sentinel's watch-map and seen-txid entries.
/// Must match `_WatchEntry.toJson` / `_SeenTx.toJson` in sentinel_service.
const sentinelWalletIdField = 'wid';

/// Removes every entry that belongs to [walletId] from Sentinel's blobs. A
/// blob left empty, or one that can't be decoded (Sentinel reads that as
/// empty anyway), is deleted.
Future<void> purgeSentinelWallet(String walletId) async {
  await _edit(
    AppConstants.keySentinelWatchMap,
    (m) => m.removeWhere((_, v) => _belongsTo(v, walletId)),
  );
  await _edit(
    AppConstants.keySentinelSeenTxids,
    (m) => m.removeWhere((_, v) => _belongsTo(v, walletId)),
  );
  await _edit(AppConstants.keySentinelBalances, (m) => m.remove(walletId));
}

bool _belongsTo(Object? entry, String walletId) =>
    entry is Map && entry[sentinelWalletIdField] == walletId;

Future<void> _edit(
  String key,
  void Function(Map<String, dynamic> blob) change,
) async {
  final raw = await bio.readSecureBlob(key);
  if (raw == null) return;
  Map<String, dynamic>? blob;
  try {
    blob = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    blob = null;
  }
  if (blob == null) {
    await bio.deleteSecureBlob(key);
    return;
  }
  final before = blob.length;
  change(blob);
  if (blob.isEmpty) {
    await bio.deleteSecureBlob(key);
  } else if (blob.length != before) {
    await bio.writeSecureBlob(key, jsonEncode(blob));
  }
}
