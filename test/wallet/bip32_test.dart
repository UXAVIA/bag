/// BIP32 derivation + address encoding tests.
///
/// Test vectors from:
///   BIP32: https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki
///   BIP84: https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki
///
/// We test the maths of child derivation using known xpub→child vectors,
/// and the full zpub→address pipeline using the BIP84 test vector.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bag/services/wallet/wallet_engine.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

Uint8List fromHex(String hex) {
  final h = hex.replaceAll(' ', '');
  return Uint8List.fromList(List.generate(
      h.length ~/ 2, (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)));
}

// ── BIP84 test vector ────────────────────────────────────────────────────────
//
// Mnemonic: abandon abandon abandon abandon abandon abandon abandon abandon
//           abandon abandon abandon about
//
// m/84'/0'/0' zpub:
//   zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs
//
// First external address (m/84'/0'/0'/0/0):
//   bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu
//
// Second external address (m/84'/0'/0'/0/1):
//   bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g
//
// First change address (m/84'/0'/0'/1/0):
//   bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el

const _bip84Zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

void main() {
  group('xpub_codec — parseZpub', () {
    test('parses valid zpub without throwing', () {
      expect(() => parseZpub(_bip84Zpub), returnsNormally);
    });

    test('rejects xpub (wrong version bytes)', () {
      // BIP44 xpub — different version
      const xpub =
          'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC5Sf4XBJ9ym3qh5sS9vf2oFGnf3DLPV';
      expect(() => parseZpub(xpub), throwsA(isA<ZpubException>()));
    });

    test('rejects string with corrupted checksum', () {
      // Flip one character — checksum must catch it.
      final bad = '${_bip84Zpub.substring(0, _bip84Zpub.length - 1)}X';
      expect(() => parseZpub(bad), throwsA(isA<ZpubException>()));
    });

    test('rejects empty string', () {
      expect(() => parseZpub(''), throwsA(isA<ZpubException>()));
    });

    test('rejects random string', () {
      expect(() => parseZpub('notazpubatall'), throwsA(isA<ZpubException>()));
    });

    test('extracted key material has correct lengths', () {
      final key = parseZpub(_bip84Zpub);
      expect(key.publicKey.length, 33);
      expect(key.chainCode.length, 32);
    });

    test('public key has valid compressed prefix', () {
      final key = parseZpub(_bip84Zpub);
      expect(key.publicKey[0] == 0x02 || key.publicKey[0] == 0x03, isTrue);
    });
  });

  group('bip32_derive — deriveChild', () {
    late ZpubKey root;

    setUp(() => root = parseZpub(_bip84Zpub));

    test('derives external branch (account=0) without throwing', () {
      expect(() => deriveChild(root, 0), returnsNormally);
    });

    test('derives change branch (account=1) without throwing', () {
      expect(() => deriveChild(root, 1), returnsNormally);
    });

    test('throws Bip32HardenedException for hardened index', () {
      expect(
        () => deriveChild(root, 0x80000000),
        throwsA(isA<Bip32HardenedException>()),
      );
    });

    test('derived key has correct structure', () {
      final child = deriveChild(root, 0);
      expect(child.publicKey.length, 33);
      expect(child.chainCode.length, 32);
      expect(child.publicKey[0] == 0x02 || child.publicKey[0] == 0x03, isTrue);
    });

    test('different indices produce different keys', () {
      final a = deriveChild(root, 0);
      final b = deriveChild(root, 1);
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });

    test('derivation is deterministic', () {
      final a = deriveChild(root, 0);
      final b = deriveChild(root, 0);
      expect(a.publicKey, equals(b.publicKey));
      expect(a.chainCode, equals(b.chainCode));
    });
  });

  group('address_encoder — pubKeyToP2wpkh', () {
    test('rejects wrong length', () {
      expect(() => pubKeyToP2wpkh(Uint8List(32)), throwsArgumentError);
    });

    test('rejects uncompressed key prefix 04', () {
      final bad = Uint8List(33)..[0] = 0x04;
      expect(() => pubKeyToP2wpkh(bad), throwsArgumentError);
    });
  });

  group('BIP84 full pipeline — zpub → address', () {
    late ZpubKey root;

    setUp(() => root = parseZpub(_bip84Zpub));

    test('first external address matches BIP84 test vector', () {
      final addr = pubKeyToP2wpkh(deriveAddress(root, 0, 0).publicKey);
      expect(addr, 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu');
    });

    test('second external address matches BIP84 test vector', () {
      final addr = pubKeyToP2wpkh(deriveAddress(root, 0, 1).publicKey);
      expect(addr, 'bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g');
    });

    test('first change address matches BIP84 test vector', () {
      final addr = pubKeyToP2wpkh(deriveAddress(root, 1, 0).publicKey);
      expect(addr, 'bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el');
    });

    test('generates bc1q prefix (native segwit)', () {
      final addr = pubKeyToP2wpkh(deriveAddress(root, 0, 0).publicKey);
      expect(addr.startsWith('bc1q'), isTrue);
    });

    test('20 consecutive addresses are all distinct', () {
      final addresses = List.generate(
        20,
        (i) => pubKeyToP2wpkh(deriveAddress(root, 0, i).publicKey),
      );
      expect(addresses.toSet().length, 20);
    });
  });
}
