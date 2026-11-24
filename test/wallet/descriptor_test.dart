/// Output-descriptor parsing, multisig script assembly and address encoding.
///
/// Test vectors from:
///   BIP67:  https://github.com/bitcoin/bips/blob/master/bip-0067.mediawiki
///           (lexicographic key sorting + resulting P2SH multisig addresses)
///   BIP380: https://github.com/bitcoin/bips/blob/master/bip-0380.mediawiki
///           (descriptor checksum)
///   BIP32:  master extended public keys used as descriptor key material
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bag/services/wallet/wallet_engine.dart';

Uint8List fromHex(String hex) {
  final h = hex.replaceAll(' ', '');
  return Uint8List.fromList(List.generate(
      h.length ~/ 2, (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)));
}

// BIP32 test-vector master public keys — valid, distinct, well-known.
const _xpub1 =
    'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8';
const _xpub2 =
    'xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB';

// BIP84 test-vector account zpub (same one used by bip32_test.dart).
const _bip84Zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

void main() {
  // ── BIP67: sorting + multisig script + P2SH address ──────────────────────
  //
  // These cover the whole non-bech32 half of the multisig pipeline:
  // key ordering, script assembly, HASH160 and base58check encoding.

  group('BIP67 sortedmulti vectors', () {
    test('vector 1 — 2-of-2', () {
      final keys = [
        fromHex(
            '02ff12471208c14bd580709cb2358d98975247d8765f92bc25eab3b2763ed605f8'),
        fromHex(
            '02fe6f0a5a297eb38c391581c4413e084773ea23954d93f7753db7dc0adc188b2f'),
      ];
      final sorted = sortPubKeysBip67(keys);

      // Sorting must put the 0x02fe… key first.
      expect(sorted.first, equals(keys[1]));

      final script = buildMultisigScript(2, sorted);
      expect(scriptToP2sh(script), '39bgKC7RFbpoCRbtD5KEdkYKtNyhpsNa3Z');
    });

    test('vector 2 — 2-of-3', () {
      final keys = [
        fromHex(
            '02632b12f4ac5b1d1b72b2a3b508c19172de44f6f46bcee50ba33f3f9291e47ed0'),
        fromHex(
            '027735a29bae7780a9755fae7a1c4374c656ac6a69ea9f3697fda61bb99a4f3e77'),
        fromHex(
            '02e2cc6bd5f45edd43bebe7cb9b675f0ce9ed3efe613b177588290ad188d11b404'),
      ];
      final script = buildMultisigScript(2, sortPubKeysBip67(keys));
      expect(scriptToP2sh(script), '3CKHTjBKxCARLzwABMu9yD85kvtm7WnMfH');
    });

    test('sorting is order-independent', () {
      final keys = [
        fromHex(
            '02e2cc6bd5f45edd43bebe7cb9b675f0ce9ed3efe613b177588290ad188d11b404'),
        fromHex(
            '02632b12f4ac5b1d1b72b2a3b508c19172de44f6f46bcee50ba33f3f9291e47ed0'),
        fromHex(
            '027735a29bae7780a9755fae7a1c4374c656ac6a69ea9f3697fda61bb99a4f3e77'),
      ];
      final script = buildMultisigScript(2, sortPubKeysBip67(keys));
      expect(scriptToP2sh(script), '3CKHTjBKxCARLzwABMu9yD85kvtm7WnMfH');
    });
  });

  group('buildMultisigScript', () {
    final pk = fromHex(
        '02632b12f4ac5b1d1b72b2a3b508c19172de44f6f46bcee50ba33f3f9291e47ed0');

    test('encodes OP_m … OP_n OP_CHECKMULTISIG', () {
      final script = buildMultisigScript(1, [pk]);
      expect(script.first, 0x51); // OP_1
      expect(script[1], 0x21); // push 33
      expect(script[script.length - 2], 0x51); // OP_1
      expect(script.last, 0xae); // OP_CHECKMULTISIG
      expect(script.length, 1 + 34 + 1 + 1);
    });

    test('rejects a threshold larger than the key count', () {
      expect(() => buildMultisigScript(2, [pk]),
          throwsA(isA<DescriptorException>()));
    });

    test('rejects an out-of-range threshold', () {
      expect(() => buildMultisigScript(0, [pk]),
          throwsA(isA<DescriptorException>()));
    });
  });

  // ── BIP380 checksum ───────────────────────────────────────────────────────

  group('descriptor checksum', () {
    const canonical =
        'wpkh([d34db33f/84h/0h/0h]xpub6DJ2dNUysrn5Vt36jH2KLBT2i1auw1tTSSomg8PhqNiUtx8QX2SvC9nrHu81fT41fvDUnhMjEzQgXnQjKEu3oaqMSzhSrHMxyyoEAmUHQbY/0/*)';

    test('accepts the BIP380 reference checksum', () {
      expect(() => parseDescriptor('$canonical#cjjspncu'), returnsNormally);
    });

    test('rejects a wrong checksum', () {
      expect(() => parseDescriptor('$canonical#cjjspncv'),
          throwsA(isA<DescriptorException>()));
    });

    test('rejects a truncated checksum', () {
      expect(() => parseDescriptor('$canonical#cjjspnc'),
          throwsA(isA<DescriptorException>()));
    });

    test('accepts a descriptor with no checksum at all', () {
      expect(() => parseDescriptor(canonical), returnsNormally);
    });
  });

  // ── Parsing ───────────────────────────────────────────────────────────────

  group('parseDescriptor', () {
    test('parses a Bitkey-style 2-of-3 wsh(sortedmulti) with multipath', () {
      final d = parseDescriptor(
        'wsh(sortedmulti(2,'
        "[aabbccdd/48h/0h/0h/2h]$_xpub1/<0;1>/*,"
        "[11223344/48h/0h/0h/2h]$_xpub2/<0;1>/*,"
        "[55667788/48h/0h/0h/2h]$_bip84Zpub/<0;1>/*))",
      );

      expect(d.scriptType, DescriptorScriptType.p2wsh);
      expect(d.threshold, 2);
      expect(d.keys.length, 3);
      expect(d.sorted, isTrue);
      expect(d.isMultisig, isTrue);
      expect(d.keys.first.receiveChain, 0);
      expect(d.keys.first.changeChain, 1);
      expect(d.summary, '2-of-3 multisig · native segwit');
    });

    test('parses nested segwit sh(wsh(sortedmulti(...)))', () {
      final d = parseDescriptor(
          'sh(wsh(sortedmulti(2,$_xpub1/<0;1>/*,$_xpub2/<0;1>/*)))');
      expect(d.scriptType, DescriptorScriptType.p2shP2wsh);
      expect(d.summary, '2-of-2 multisig · nested segwit');
    });

    test('parses unsorted multi()', () {
      final d =
          parseDescriptor('wsh(multi(1,$_xpub1/0/*,$_xpub2/0/*))');
      expect(d.sorted, isFalse);
      expect(d.keys.first.changeChain, isNull);
    });

    test('parses single-key wpkh', () {
      final d = parseDescriptor('wpkh($_bip84Zpub/<0;1>/*)');
      expect(d.scriptType, DescriptorScriptType.p2wpkh);
      expect(d.isMultisig, isFalse);
      expect(d.summary, 'single key · native segwit');
    });

    test('tolerates whitespace and newlines from a pasted export', () {
      final d = parseDescriptor(
          '  wsh(sortedmulti(2,\n  $_xpub1/<0;1>/*,\n  $_xpub2/<0;1>/*))  ');
      expect(d.threshold, 2);
    });

    test('rejects a private key', () {
      expect(
        () => parseDescriptor(
            'wpkh(xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi/0/*)'),
        throwsA(isA<DescriptorException>()),
      );
    });

    test('rejects taproot with an explicit message', () {
      expect(
        () => parseDescriptor('tr($_xpub1/<0;1>/*)'),
        throwsA(predicate((e) =>
            e is DescriptorException && e.message.contains('Taproot'))),
      );
    });

    test('rejects hardened derivation after the extended key', () {
      expect(
        () => parseDescriptor('wpkh($_xpub1/0h/*)'),
        throwsA(isA<DescriptorException>()),
      );
    });

    test('rejects cosigners with mismatched chains', () {
      expect(
        () => parseDescriptor(
            'wsh(sortedmulti(2,$_xpub1/<0;1>/*,$_xpub2/0/*))'),
        throwsA(isA<DescriptorException>()),
      );
    });

    test('rejects a threshold above the key count', () {
      expect(
        () => parseDescriptor(
            'wsh(sortedmulti(3,$_xpub1/<0;1>/*,$_xpub2/<0;1>/*))'),
        throwsA(isA<DescriptorException>()),
      );
    });

    test('rejects unbalanced parentheses', () {
      expect(
        () => parseDescriptor('wsh(sortedmulti(2,$_xpub1/<0;1>/*)'),
        throwsA(isA<DescriptorException>()),
      );
    });

    test('rejects a bare (non-extended) public key', () {
      expect(
        () => parseDescriptor(
            'wsh(sortedmulti(1,02632b12f4ac5b1d1b72b2a3b508c19172de44f6f46bcee50ba33f3f9291e47ed0))'),
        throwsA(isA<DescriptorException>()),
      );
    });

    test('rejects an empty descriptor', () {
      expect(() => parseDescriptor('   '),
          throwsA(isA<DescriptorException>()));
    });
  });

  // ── Address derivation ────────────────────────────────────────────────────

  group('DescriptorAddressSource', () {
    final multisig = DescriptorAddressSource(parseDescriptor(
        'wsh(sortedmulti(2,$_xpub1/<0;1>/*,$_xpub2/<0;1>/*))'));

    test('produces valid-looking P2WSH addresses on both chains', () {
      final receive = multisig.addressAt(0, 0);
      final change = multisig.addressAt(1, 0);

      expect(receive.startsWith('bc1q'), isTrue);
      // A witness-v0 script hash is 32 bytes → 62-character bech32 address.
      expect(receive.length, 62);
      expect(change.length, 62);
      expect(receive, isNot(change));
    });

    test('is deterministic', () {
      expect(multisig.addressAt(0, 7), multisig.addressAt(0, 7));
    });

    test('key order in the descriptor does not change the address', () {
      final reversed = DescriptorAddressSource(parseDescriptor(
          'wsh(sortedmulti(2,$_xpub2/<0;1>/*,$_xpub1/<0;1>/*))'));
      expect(multisig.addressAt(0, 0), reversed.addressAt(0, 0));
    });

    test('unsorted multi() IS order-dependent', () {
      final a = DescriptorAddressSource(
          parseDescriptor('wsh(multi(2,$_xpub1/<0;1>/*,$_xpub2/<0;1>/*))'));
      final b = DescriptorAddressSource(
          parseDescriptor('wsh(multi(2,$_xpub2/<0;1>/*,$_xpub1/<0;1>/*))'));
      expect(a.addressAt(0, 0), isNot(b.addressAt(0, 0)));
    });

    test('receive-only descriptor reports no change chain', () {
      final source = DescriptorAddressSource(
          parseDescriptor('wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))'));
      expect(source.hasChain(0), isTrue);
      expect(source.hasChain(1), isFalse);
    });

    test('single-key wpkh descriptor matches the plain zpub pipeline', () {
      // wpkh(zpub/<0;1>/*) must derive exactly the same addresses as the
      // BIP84 single-sig path, or the two wallet kinds would disagree.
      final viaDescriptor =
          DescriptorAddressSource(parseDescriptor('wpkh($_bip84Zpub/<0;1>/*)'));
      final viaZpub = ZpubAddressSource(parseZpub(_bip84Zpub));

      expect(viaDescriptor.addressAt(0, 0),
          'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu');
      expect(viaDescriptor.addressAt(0, 0), viaZpub.addressAt(0, 0));
      expect(viaDescriptor.addressAt(1, 0), viaZpub.addressAt(1, 0));
    });
  });

  // ── Multi-descriptor pastes (Bitkey / Sparrow exports) ────────────────────

  group('multi-descriptor paste', () {
    // Exactly what Bitkey's "Export wallet descriptor" produces
    // (ExportWatchingDescriptorServiceImpl): two labelled lines, receive and
    // change split apart, a blank line between, no checksums.
    final bitkeyExport = 'External: wsh(sortedmulti(2,[deadbeef/84h/0h/0h]'
        '$_xpub1/0/*,[cafebabe/84h/0h/0h]$_xpub2/0/*))\n'
        '\n'
        'Internal: wsh(sortedmulti(2,[deadbeef/84h/0h/0h]'
        '$_xpub1/1/*,[cafebabe/84h/0h/0h]$_xpub2/1/*))';
    final multipath =
        parseDescriptor('wsh(sortedmulti(2,$_xpub1/<0;1>/*,$_xpub2/<0;1>/*))');

    test('Bitkey export pasted verbatim becomes one two-chain wallet', () {
      final d = parseDescriptor(bitkeyExport);
      expect(d.isMultisig, isTrue);
      expect(d.threshold, 2);
      expect(d.keys.length, 2);
      expect(d.keys.first.receiveChain, 0);
      expect(d.keys.first.changeChain, 1);
      expect(d.isReceiveOnly, isFalse);
      expect(d.summary, '2-of-2 multisig · native segwit');

      // Must derive exactly what the <0;1> form derives on both chains.
      final a = DescriptorAddressSource(d);
      final b = DescriptorAddressSource(multipath);
      expect(a.hasChain(1), isTrue);
      expect(a.addressAt(0, 0), b.addressAt(0, 0));
      expect(a.addressAt(0, 7), b.addressAt(0, 7));
      expect(a.addressAt(1, 0), b.addressAt(1, 0));
      expect(a.addressAt(1, 3), b.addressAt(1, 3));
    });

    test('order of the External and Internal lines does not matter', () {
      final lines = bitkeyExport.split('\n\n');
      final d = parseDescriptor('${lines[1]}\n${lines[0]}');
      expect(d.keys.first.receiveChain, 0);
      expect(d.keys.first.changeChain, 1);
    });

    test('sortedmulti cosigners may be listed in a different order', () {
      final d = parseDescriptor(
          'External: wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))\n'
          'Internal: wsh(sortedmulti(2,$_xpub2/1/*,$_xpub1/1/*))');
      expect(d.keys.first.changeChain, 1);
      expect(DescriptorAddressSource(d).addressAt(1, 0),
          DescriptorAddressSource(multipath).addressAt(1, 0));
    });

    test('multi() cosigner order is part of the script — reordering is '
        'a different wallet', () {
      expect(
          () => parseDescriptor(
              'wsh(multi(2,$_xpub1/0/*,$_xpub2/0/*))\n'
              'wsh(multi(2,$_xpub2/1/*,$_xpub1/1/*))'),
          throwsA(isA<DescriptorException>()));
    });

    test('Sparrow export: comments, a <0;1> descriptor plus both halves', () {
      final d = parseDescriptor('# Receive and change descriptor:\n'
          'wsh(sortedmulti(2,$_xpub1/<0;1>/*,$_xpub2/<0;1>/*))\n'
          '\n\n'
          '# Receive descriptor:\n'
          'wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))\n'
          '\n'
          '# Change descriptor:\n'
          'wsh(sortedmulti(2,$_xpub1/1/*,$_xpub2/1/*))\n');
      expect(d.keys.first.receiveChain, 0);
      expect(d.keys.first.changeChain, 1);
    });

    test('a single descriptor wrapped across lines still parses', () {
      final d = parseDescriptor('wsh(sortedmulti(2,\n'
          '  $_xpub1/<0;1>/*,\n'
          '  $_xpub2/<0;1>/*\n'
          '))');
      expect(d.keys.first.changeChain, 1);
    });

    test('checksummed descriptors are split correctly', () {
      // The checksum of each half is verified individually, so a wrong one
      // is still fatal.
      expect(
          () => parseDescriptor(
              'wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))#qqqqqqqq\n'
              'wsh(sortedmulti(2,$_xpub1/1/*,$_xpub2/1/*))'),
          throwsA(isA<DescriptorException>().having(
              (e) => e.message, 'message', contains('checksum'))));
    });

    test('descriptors of different wallets are rejected', () {
      expect(
          () => parseDescriptor(
              'External: wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))\n'
              'Internal: wsh(sortedmulti(2,$_xpub1/1/*,$_bip84Zpub/1/*))'),
          throwsA(isA<DescriptorException>().having(
              (e) => e.message, 'message', contains('different wallets'))));
      expect(
          () => parseDescriptor(
              'wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))\n'
              'wsh(sortedmulti(1,$_xpub1/1/*,$_xpub2/1/*))'),
          throwsA(isA<DescriptorException>()));
      expect(
          () => parseDescriptor(
              'wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))\n'
              'sh(wsh(sortedmulti(2,$_xpub1/1/*,$_xpub2/1/*)))'),
          throwsA(isA<DescriptorException>()));
    });

    test('more than two chains is rejected', () {
      expect(
          () => parseDescriptor(
              'wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))\n'
              'wsh(sortedmulti(2,$_xpub1/1/*,$_xpub2/1/*))\n'
              'wsh(sortedmulti(2,$_xpub1/2/*,$_xpub2/2/*))'),
          throwsA(isA<DescriptorException>().having(
              (e) => e.message, 'message', contains('3 address chains'))));
    });

    test('a lone receive-only descriptor parses but is flagged', () {
      final d = parseDescriptor(
          'External: wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))');
      expect(d.isReceiveOnly, isTrue);
      expect(d.summary, '2-of-2 multisig · native segwit · receive-only');
      expect(DescriptorAddressSource(d).hasChain(1), isFalse);
    });

    test('a private key inside a labelled line is still caught first', () {
      expect(
          () => parseDescriptor(
              'External: wsh(sortedmulti(2,xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi/0/*,$_xpub2/0/*))'),
          throwsA(isA<DescriptorException>().having(
              (e) => e.message, 'message', contains('private'))));
    });
  });

  group('ZpubAddressSource', () {
    final source = ZpubAddressSource(parseZpub(_bip84Zpub));

    test('matches the BIP84 test vector', () {
      expect(source.addressAt(0, 0),
          'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu');
      expect(source.addressAt(0, 1),
          'bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g');
      expect(source.addressAt(1, 0),
          'bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el');
    });

    test('exposes exactly the receive and change chains', () {
      expect(source.hasChain(0), isTrue);
      expect(source.hasChain(1), isTrue);
      expect(source.hasChain(2), isFalse);
    });
  });

  group('parseExtendedPubKey', () {
    test('accepts xpub, ypub-family and zpub', () {
      expect(() => parseExtendedPubKey(_xpub1), returnsNormally);
      expect(() => parseExtendedPubKey(_bip84Zpub), returnsNormally);
    });

    test('rejects private keys with an explicit warning', () {
      expect(
        () => parseExtendedPubKey(
            'xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi'),
        throwsA(predicate((e) =>
            e is ZpubException && e.message.contains('PRIVATE'))),
      );
    });

    test('rejects a corrupted checksum', () {
      final corrupted = '${_xpub1.substring(0, _xpub1.length - 1)}X';
      expect(() => parseExtendedPubKey(corrupted),
          throwsA(isA<ZpubException>()));
    });
  });
}
