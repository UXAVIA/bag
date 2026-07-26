part of 'wallet_engine.dart';

/// Strict zpub parsing and validation.
///
/// Security invariants:
/// - Checksum verified before any byte is read.
/// - Version bytes must be exactly 0x04B24746 (zpub mainnet).
/// - Public key validated as a point on secp256k1.
/// - No fallbacks — any anomaly throws [ZpubException].
/// - The raw zpub string is NEVER logged.

// zpub mainnet version bytes (BIP84).
const _zpubVersion = [0x04, 0xB2, 0x47, 0x46];

// BIP32 serialisation: 4 version + 1 depth + 4 fingerprint + 4 index +
// 32 chaincode + 33 pubkey = 78 bytes total.
const _expectedPayloadLength = 78;

const _base58Alphabet =
    '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// Immutable, validated zpub key material.
/// Created only through [parseZpub] or [deriveChild] — never directly.
final class ZpubKey {
  /// Compressed secp256k1 public key (33 bytes).
  final Uint8List publicKey;

  /// BIP32 chain code (32 bytes).
  final Uint8List chainCode;

  ZpubKey._({required this.publicKey, required this.chainCode});
}

/// Thrown when a zpub string fails any validation step.
final class ZpubException implements Exception {
  final String message;
  const ZpubException(this.message);

  @override
  String toString() => 'ZpubException: $message';
}

/// Parses and strictly validates a zpub string.
/// Throws [ZpubException] for any invalid input. Never logs the input.
ZpubKey parseZpub(String zpub) {
  if (!zpub.startsWith('zpub')) {
    throw const ZpubException(
        'Not a zpub — only native segwit (zpub) is supported');
  }

  final Uint8List payload;
  try {
    payload = _base58CheckDecode(zpub);
  } on FormatException catch (e) {
    throw ZpubException('Invalid encoding: ${e.message}');
  }

  if (payload.length != _expectedPayloadLength) {
    throw ZpubException(
        'Invalid length: expected $_expectedPayloadLength bytes, '
        'got ${payload.length}');
  }

  for (int i = 0; i < 4; i++) {
    if (payload[i] != _zpubVersion[i]) {
      throw const ZpubException(
          'Wrong version bytes — only zpub (BIP84 mainnet) accepted');
    }
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

// ── Shared crypto utilities (used by all parts) ──────────────────────────────

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
