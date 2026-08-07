part of 'wallet_engine.dart';

/// Converts a compressed secp256k1 public key to a P2WPKH bech32 address.
/// Implements BIP173 bech32 and BIP141 P2WPKH. No external Bitcoin packages.
/// No keys or addresses are logged anywhere in this file.

/// Returns the mainnet P2WPKH bech32 address for [compressedPubKey].
/// Throws [ArgumentError] if the key is not a valid 33-byte compressed key.
String pubKeyToP2wpkh(Uint8List compressedPubKey) {
  if (compressedPubKey.length != 33 ||
      (compressedPubKey[0] != 0x02 && compressedPubKey[0] != 0x03)) {
    throw ArgumentError('Expected 33-byte compressed public key');
  }
  return _bech32Encode('bc', 0, _hash160(compressedPubKey));
}

/// Returns the mainnet P2WSH bech32 address for [script] (the witness script).
/// Used by `wsh(...)` descriptors — notably multisig.
String scriptToP2wsh(Uint8List script) =>
    _bech32Encode('bc', 0, _sha256(script));

/// Returns the mainnet P2SH address wrapping a P2WSH witness script
/// (`sh(wsh(...))` descriptors).
String scriptToP2shWsh(Uint8List script) {
  // redeemScript = OP_0 PUSH32 <sha256(witnessScript)>
  final witnessProgram = _sha256(script);
  final redeem = Uint8List(2 + witnessProgram.length)
    ..[0] = 0x00
    ..[1] = 0x20
    ..setRange(2, 2 + witnessProgram.length, witnessProgram);
  return _p2shAddress(redeem);
}

/// Returns the mainnet P2SH address for a bare redeem [script]
/// (`sh(...)` descriptors — legacy multisig).
String scriptToP2sh(Uint8List script) => _p2shAddress(script);

/// Returns the mainnet P2SH-P2WPKH ("nested segwit") address for
/// [compressedPubKey] — `sh(wpkh(...))` descriptors.
String pubKeyToP2shWpkh(Uint8List compressedPubKey) {
  _requireCompressed(compressedPubKey);
  final keyHash = _hash160(compressedPubKey);
  // redeemScript = OP_0 PUSH20 <hash160(pubkey)>
  final redeem = Uint8List(2 + keyHash.length)
    ..[0] = 0x00
    ..[1] = 0x14
    ..setRange(2, 2 + keyHash.length, keyHash);
  return _p2shAddress(redeem);
}

/// Returns the mainnet P2PKH (legacy) address for [compressedPubKey].
String pubKeyToP2pkh(Uint8List compressedPubKey) {
  _requireCompressed(compressedPubKey);
  final hash = _hash160(compressedPubKey);
  final payload = Uint8List(1 + hash.length)
    ..[0] = 0x00 // mainnet P2PKH version byte
    ..setRange(1, 1 + hash.length, hash);
  return _base58CheckEncode(payload);
}

String _p2shAddress(Uint8List redeemScript) {
  final hash = _hash160(redeemScript);
  final payload = Uint8List(1 + hash.length)
    ..[0] = 0x05 // mainnet P2SH version byte
    ..setRange(1, 1 + hash.length, hash);
  return _base58CheckEncode(payload);
}

void _requireCompressed(Uint8List key) {
  if (key.length != 33 || (key[0] != 0x02 && key[0] != 0x03)) {
    throw ArgumentError('Expected 33-byte compressed public key');
  }
}

// ── HASH160 ──────────────────────────────────────────────────────────────────

Uint8List _hash160(Uint8List data) {
  final sha256 = SHA256Digest().process(data);
  return RIPEMD160Digest().process(sha256);
}

// ── Bech32 (BIP173) ──────────────────────────────────────────────────────────

const _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const _bech32Generator = [
  0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3,
];

String _bech32Encode(String hrp, int witVer, Uint8List witProg) {
  final data5 = _convertBits(witProg, 8, 5, pad: true);
  final payload = [witVer, ...data5];
  final checksum = _bech32Checksum(hrp, payload);
  final sb = StringBuffer('${hrp}1');
  for (final v in [...payload, ...checksum]) {
    sb.write(_bech32Charset[v]);
  }
  return sb.toString();
}

List<int> _convertBits(Uint8List data, int from, int to, {required bool pad}) {
  int acc = 0, bits = 0;
  final result = <int>[];
  final maxv = (1 << to) - 1;
  for (final value in data) {
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      result.add((acc >> bits) & maxv);
    }
  }
  if (pad && bits > 0) result.add((acc << (to - bits)) & maxv);
  return result;
}

int _bech32Polymod(List<int> values) {
  int chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (int i = 0; i < 5; i++) {
      if ((top >> i) & 1 == 1) chk ^= _bech32Generator[i];
    }
  }
  return chk;
}

List<int> _hrpExpand(String hrp) => [
      ...hrp.codeUnits.map((c) => c >> 5),
      0,
      ...hrp.codeUnits.map((c) => c & 0x1f),
    ];

List<int> _bech32Checksum(String hrp, List<int> data) {
  final polymod =
      _bech32Polymod([..._hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
  return List.generate(6, (i) => (polymod >> (5 * (5 - i))) & 0x1f);
}
