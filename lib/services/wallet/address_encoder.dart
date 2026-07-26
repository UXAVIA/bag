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
