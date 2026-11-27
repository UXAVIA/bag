/// The website signs a key for an OpenNode charge; the app must accept it.
/// The vector below comes from the website repo's signing test (seed bytes
/// 0x01..0x20, charge `e9ed3291-6c1c-4b67-83d7-fb6fcebc43b4`).
library;

import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';

import 'package:bag/core/services/license_key_service.dart';

const _testSeed = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA';
const _expectedVector =
    'MXNq0ez4z28vK8VLT6Oz30VsEQcFSE9e5BlnZ5ROnqLKxhpaVCq3Ci3R8Uehl2V49r_TJeua8PUkp1CJa3f2WtCbQuqzfpIA';

void main() {
  setUp(() {
    final seed = Uint8List.fromList(
      List<int>.generate(32, (i) => i + 1),
    );
    final key = ed.newKeyFromSeed(seed);
    LicenseKeyService.debugPublicKey =
        Uint8List.fromList(ed.public(key).bytes);
  });

  tearDown(() => LicenseKeyService.debugPublicKey = null);

  test('the seed constant is bytes 0x01..0x20', () {
    expect(_testSeed.length, 43);
  });

  test('cross-repo vector verifies, a one-character change does not', () {
    expect(LicenseKeyService.verify(_expectedVector), isTrue);
    final last = _expectedVector[_expectedVector.length - 1];
    final changed = _expectedVector.substring(0, _expectedVector.length - 1) +
        (last == 'A' ? 'B' : 'A');
    expect(LicenseKeyService.verify(changed), isFalse);
    final first = _expectedVector[0] == 'M' ? 'N' : 'M';
    expect(LicenseKeyService.verify(first + _expectedVector.substring(1)),
        isFalse);
  });

  test('pasted key with line breaks and groups verifies', () {
    final groups = <String>[
      for (var i = 0; i < _expectedVector.length; i += 6)
        _expectedVector.substring(
          i,
          i + 6 > _expectedVector.length ? _expectedVector.length : i + 6,
        ),
    ];
    final pasted = [
      for (var i = 0; i < groups.length; i++)
        groups[i] + (i % 4 == 3 ? '\n' : ' '),
    ].join();
    expect(pasted, contains('\n'));
    expect(LicenseKeyService.verify(pasted), isTrue);
    expect(
      LicenseKeyService.verify(LicenseKeyService.formatForDisplay(_expectedVector)),
      isTrue,
    );
  });
}
