part of 'wallet_engine.dart';

/// Strict extended-public-key parsing and validation.
///
/// Security invariants:
/// - Checksum verified before any byte is read.
/// - Version bytes must match a known mainnet *public* prefix. Private
///   prefixes (xprv/yprv/zprv/…) and all testnet prefixes are rejected.
/// - Public key validated as a point on secp256k1.
/// - No fallbacks — any anomaly throws [ZpubException].
/// - The raw key string is NEVER logged.

// Mainnet extended *public* key version bytes.
// Single-sig:
const _versionXpub = 0x0488B21E; // BIP44  P2PKH        (xpub)
const _versionYpub = 0x049D7CB2; // BIP49  P2SH-P2WPKH  (ypub)
const _versionZpub = 0x04B24746; // BIP84  P2WPKH       (zpub)
// Multisig (SLIP-132):
const _versionYpubMulti = 0x0295B43F; // P2SH-P2WSH multisig (Ypub)
const _versionZpubMulti = 0x02AA7ED3; // P2WSH multisig      (Zpub)

/// Every mainnet public prefix we are willing to decode.
/// Descriptors normally carry plain `xpub`, but hardware wallets and
/// coordinators frequently paste SLIP-132 variants — all of them serialise
/// the same 33-byte pubkey + 32-byte chain code, so the prefix only tells us
/// the *intended* script type, which the descriptor already states.
const _acceptedPublicVersions = <int>{
  _versionXpub,
  _versionYpub,
  _versionZpub,
  _versionYpubMulti,
  _versionZpubMulti,
};

// BIP32 serialisation: 4 version + 1 depth + 4 fingerprint + 4 index +
// 32 chaincode + 33 pubkey = 78 bytes total.
const _expectedPayloadLength = 78;

const _base58Alphabet =
    '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// Immutable, validated extended public key material.
/// Created only through [parseZpub], [parseExtendedPubKey] or [deriveChild] —
/// never directly.
final class ZpubKey {
  /// Compressed secp256k1 public key (33 bytes).
  final Uint8List publicKey;

  /// BIP32 chain code (32 bytes).
  final Uint8List chainCode;

  ZpubKey._({required this.publicKey, required this.chainCode});
}

/// Thrown when an extended public key fails any validation step.
final class ZpubException implements Exception {
  final String message;
  const ZpubException(this.message);

  @override
  String toString() => 'ZpubException: $message';
}

/// Parses and strictly validates a zpub string (BIP84 mainnet only).
///
/// Used by the single-sig "add wallet" flow, which deliberately accepts
/// nothing else so that a user pasting an xpub gets a clear error rather than
/// a silently wrong address set.
///
/// Throws [ZpubException] for any invalid input. Never logs the input.
ZpubKey parseZpub(String zpub) {
  if (!zpub.startsWith('zpub')) {
    throw const ZpubException(
        'Not a zpub — only native segwit (zpub) is supported');
  }
  return _decodeExtendedKey(zpub, allowed: const {_versionZpub});
}

/// Parses any supported mainnet extended *public* key.
///
/// Used when decoding keys embedded in an output descriptor, where the
/// descriptor itself — not the key prefix — determines the script type.
ZpubException? _privateKeyPrefixError(String key) {
  const privatePrefixes = ['xprv', 'yprv', 'zprv', 'Yprv', 'Zprv'];
  for (final p in privatePrefixes) {
    if (key.startsWith(p)) {
      return const ZpubException(
        'That is a PRIVATE key. Never enter a private key — '
        'Bag only ever needs public keys.',
      );
    }
  }
  return null;
}

ZpubKey parseExtendedPubKey(String key) {
  final privateError = _privateKeyPrefixError(key);
  if (privateError != null) throw privateError;
  return _decodeExtendedKey(key, allowed: _acceptedPublicVersions);
}

ZpubKey _decodeExtendedKey(String key, {required Set<int> allowed}) {
  final Uint8List payload;
  try {
    payload = _base58CheckDecode(key);
  } on FormatException catch (e) {
    throw ZpubException('Invalid encoding: ${e.message}');
  }

  if (payload.length != _expectedPayloadLength) {
    throw ZpubException(
        'Invalid length: expected $_expectedPayloadLength bytes, '
        'got ${payload.length}');
  }

  final version = (payload[0] << 24) |
      (payload[1] << 16) |
      (payload[2] << 8) |
      payload[3];
  if (!allowed.contains(version)) {
    throw const ZpubException(
        'Unsupported key — expected a mainnet extended public key');
  }

  final chainCode = Uint8List.fromList(payload.sublist(13, 45));
  final publicKey = Uint8List.fromList(payload.sublist(45, 78));

  _validateSecp256k1Point(publicKey);

  return ZpubKey._(publicKey: publicKey, chainCode: chainCode);
}

// ── Base58check ──────────────────────────────────────────────────────────────

Uint8List _base58CheckDecode(String input) {
  var value = BigInt.zero;
  for (final codeUnit in input.codeUnits) {
    final digit = _base58Alphabet.indexOf(String.fromCharCode(codeUnit));
    if (digit == -1) throw const FormatException('invalid base58 character');
    value = value * BigInt.from(58) + BigInt.from(digit);
  }

  int leadingZeros = 0;
  for (final ch in input.split('')) {
    if (ch == '1') {
      leadingZeros++;
    } else {
      break;
    }
  }

  final bytes = _bigIntToMinBytes(value);
  final full = Uint8List(leadingZeros + bytes.length)
    ..setRange(leadingZeros, leadingZeros + bytes.length, bytes);

  if (full.length < 4) throw const FormatException('input too short');

  final payload = full.sublist(0, full.length - 4);
  final checksum = full.sublist(full.length - 4);
  final computed = _sha256d(payload).sublist(0, 4);

  if (!_bytesEqual(checksum, computed)) {
    throw const FormatException('checksum mismatch');
  }

  return payload;
}

// ── Secp256k1 point validation ───────────────────────────────────────────────

final _secp256k1Params = ECCurve_secp256k1();

void _validateSecp256k1Point(Uint8List pubKey) {
  if (pubKey.length != 33) {
    throw const ZpubException('Public key must be 33 bytes (compressed)');
  }
  if (pubKey[0] != 0x02 && pubKey[0] != 0x03) {
    throw const ZpubException(
        'Public key must be compressed (02 or 03 prefix)');
  }
  try {
    final point = _secp256k1Params.curve.decodePoint(pubKey);
    if (point == null || point.isInfinity) {
      throw const ZpubException('Public key is not a valid secp256k1 point');
    }
  } catch (e) {
    if (e is ZpubException) rethrow;
    throw const ZpubException('Public key is not a valid secp256k1 point');
  }
}

/// Base58check-encodes [payload] (version byte already prepended).
/// Used for P2SH addresses produced by `sh(...)` descriptors.
String _base58CheckEncode(Uint8List payload) {
  final checksum = _sha256d(payload).sublist(0, 4);
  final full = Uint8List(payload.length + 4)
    ..setRange(0, payload.length, payload)
    ..setRange(payload.length, payload.length + 4, checksum);

  var value = _bytesToBigInt(full);
  final sb = StringBuffer();
  final base = BigInt.from(58);
  while (value > BigInt.zero) {
    final rem = (value % base).toInt();
    sb.write(_base58Alphabet[rem]);
    value = value ~/ base;
  }
  // Each leading zero byte encodes to a literal '1'.
  for (final b in full) {
    if (b != 0) break;
    sb.write('1');
  }
  return String.fromCharCodes(sb.toString().codeUnits.reversed);
}

// ── Shared crypto utilities (used by all parts) ──────────────────────────────

Uint8List _sha256(Uint8List data) => SHA256Digest().process(data);

Uint8List _sha256d(Uint8List data) {
  final d = SHA256Digest();
  return d.process(d.process(data));
}

Uint8List _bigIntToMinBytes(BigInt value) {
  if (value == BigInt.zero) return Uint8List(1);
  final hex = value.toRadixString(16);
  final padded = hex.length.isOdd ? '0$hex' : hex;
  final bytes = Uint8List(padded.length ~/ 2);
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(padded.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

BigInt _bytesToBigInt(Uint8List bytes) {
  BigInt result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}
