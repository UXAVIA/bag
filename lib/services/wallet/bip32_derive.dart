part of 'wallet_engine.dart';

/// BIP32 public child key derivation for secp256k1.
///
/// Security invariants:
/// - Only non-hardened derivation (index < 0x80000000).
/// - IL ≥ curve order n → [Bip32InvalidChildException] (caller skips index).
/// - Point at infinity → [Bip32InvalidChildException].
/// - No sensitive material is logged.

/// Thrown when a derived child key is cryptographically invalid.
/// Per BIP32 §4: skip this index and try the next.
final class Bip32InvalidChildException implements Exception {
  const Bip32InvalidChildException();
  @override
  String toString() => 'Bip32InvalidChildException: skip this index';
}

/// Thrown when hardened derivation is attempted with a public key.
final class Bip32HardenedException implements Exception {
  const Bip32HardenedException();
  @override
  String toString() =>
      'Bip32HardenedException: hardened derivation requires a private key';
}

// Reuse the secp256k1 params instance from xpub_codec.dart (same library).
// Curve order n — any IL ≥ n means invalid child key.
final _curveN = _secp256k1Params.n;

/// Derives a non-hardened BIP32 public child key.
///
/// Throws [Bip32HardenedException] if index ≥ 0x80000000.
/// Throws [Bip32InvalidChildException] if the derived key is invalid
/// (BIP32 spec requires caller to skip and try next index).
ZpubKey deriveChild(ZpubKey parent, int index) {
  if (index < 0 || index >= 0x80000000) {
    throw const Bip32HardenedException();
  }

  // data = pubkey (33 bytes) || index (4 bytes, big-endian)
  final data = Uint8List(37);
  data.setRange(0, 33, parent.publicKey);
  ByteData.sublistView(data, 33).setUint32(0, index, Endian.big);

  // hmacOut = HMAC-SHA512(key=chainCode, data=data) per BIP32 notation I=IL||IR
  final hmacOut = _hmacSha512(parent.chainCode, data);
  final il = hmacOut.sublist(0, 32);  // left 32 bytes: scalar addend
  final ir = hmacOut.sublist(32, 64); // right 32 bytes: child chain code

  // Reject if il ≥ n (probability ~1 in 2^127 but spec mandates the check).
  if (_bytesToBigInt(il) >= _curveN) throw const Bip32InvalidChildException();

  // child_pubkey = point(il) + parent_pubkey  =  (il × G) + parent_pubkey
  final ilScalar = _bytesToBigInt(il);
  final ilPoint = (_secp256k1Params.G * ilScalar)!;
  if (ilPoint.isInfinity) throw const Bip32InvalidChildException();

  final parentPoint = _secp256k1Params.curve.decodePoint(parent.publicKey);
  if (parentPoint == null || parentPoint.isInfinity) {
    throw const Bip32InvalidChildException();
  }

  final childPoint = (ilPoint + parentPoint)!;
  if (childPoint.isInfinity) throw const Bip32InvalidChildException();

  return ZpubKey._(
    publicKey: Uint8List.fromList(childPoint.getEncoded(true)),
    chainCode: Uint8List.fromList(ir),
  );
}

/// Convenience: derives the key at [account]/[index] from [root].
///
/// account = 0 → external (receiving) addresses
/// account = 1 → internal (change) addresses
ZpubKey deriveAddress(ZpubKey root, int account, int index) {
  assert(account == 0 || account == 1);
  assert(index >= 0 && index < 0x80000000);
  return deriveChild(deriveChild(root, account), index);
}

// ── Internal ──────────────────────────────────────────────────────────────────

Uint8List _hmacSha512(Uint8List key, Uint8List data) {
  final hmac = HMac(SHA512Digest(), 128)..init(KeyParameter(key));
  final result = Uint8List(64);
  hmac
    ..update(data, 0, data.length)
    ..doFinal(result, 0);
  return result;
}
