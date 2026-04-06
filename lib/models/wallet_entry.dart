import 'dart:convert';

/// A single watch-only wallet (zpub) with its cached scan state.
///
/// The zpub is NOT stored here — it lives in FlutterSecureStorage keyed by [id].
/// Only metadata safe to persist in SharedPreferences is stored in this model.
final class WalletEntry {
  final String id;
  final String label;
  final int? lastSats;
  final DateTime? lastScanAt;
  final int usedAddresses;

  /// Last scanned external (receive) address index — used to re-derive
  /// addresses for chain analysis without re-scanning.
  final int lastExternalIndex;

  /// Last scanned change address index.
  final int lastChangeIndex;

  // Transient scan state — NOT persisted.
  final bool isScanning;
  final int scanProgress;
  final String? scanError;

  const WalletEntry({
    required this.id,
    required this.label,
    this.lastSats,
    this.lastScanAt,
    this.usedAddresses = 0,
    this.lastExternalIndex = 0,
    this.lastChangeIndex = 0,
    this.isScanning = false,
    this.scanProgress = 0,
    this.scanError,
  });

  double get btcAmount => (lastSats ?? 0) / 1e8;

  bool get isStale {
    if (lastScanAt == null) return true;
    return DateTime.now().difference(lastScanAt!) > const Duration(minutes: 15);
  }

  // Sentinel so copyWith can explicitly clear nullable fields.
  static const _keep = Object();

  WalletEntry copyWith({
    String? id,
    String? label,
    int? lastSats,
    DateTime? lastScanAt,
    int? usedAddresses,
    int? lastExternalIndex,
    int? lastChangeIndex,
    bool? isScanning,
    int? scanProgress,
    Object? scanError = _keep,
  }) =>
      WalletEntry(
        id: id ?? this.id,
        label: label ?? this.label,
        lastSats: lastSats ?? this.lastSats,
        lastScanAt: lastScanAt ?? this.lastScanAt,
        usedAddresses: usedAddresses ?? this.usedAddresses,
        lastExternalIndex: lastExternalIndex ?? this.lastExternalIndex,
        lastChangeIndex: lastChangeIndex ?? this.lastChangeIndex,
        isScanning: isScanning ?? this.isScanning,
        scanProgress: scanProgress ?? this.scanProgress,
        scanError: scanError == _keep ? this.scanError : scanError as String?,
      );

  /// Serialises only the stable metadata fields — not transient scan state.
  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (lastSats != null) 'lastSats': lastSats,
        if (lastScanAt != null)
          'lastScanAt': lastScanAt!.millisecondsSinceEpoch,
        'usedAddresses': usedAddresses,
        'lastExternalIndex': lastExternalIndex,
        'lastChangeIndex': lastChangeIndex,
      };

  factory WalletEntry.fromJson(Map<String, dynamic> json) => WalletEntry(
        id: json['id'] as String,
        label: json['label'] as String,
        lastSats: json['lastSats'] as int?,
        lastScanAt: json['lastScanAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['lastScanAt'] as int)
            : null,
        usedAddresses: json['usedAddresses'] as int? ?? 0,
        lastExternalIndex: json['lastExternalIndex'] as int? ?? 0,
        lastChangeIndex: json['lastChangeIndex'] as int? ?? 0,
      );

  static List<WalletEntry> listFromJson(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => WalletEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String listToJsonString(List<WalletEntry> entries) =>
      jsonEncode(entries.map((e) => e.toJson()).toList());
}
