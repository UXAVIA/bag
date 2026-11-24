import 'dart:convert';
import 'dart:io';

import 'package:bag/core/licenses/register_licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The notices Flutter doesn't collect itself (the Rust crates of the tor
// plugin's native library, the C sources bundled in them, and the Android
// libraries plugins pull in), as the in-app licence page shows them, and as
// THIRD_PARTY_NOTICES.md lists them for the public tree. Both are generated
// by tools/licenses/generate.sh; these tests read the committed outputs.

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// Every entry registerThirdPartyLicenses() adds, for one platform and
/// flavor. The flutter_test binding registers none of Flutter's own (its
/// initLicenses is a no-op), so the registry holds only these.
Future<List<LicenseEntry>> _entries({
  TargetPlatform platform = TargetPlatform.android,
  String flavor = 'direct',
}) async {
  LicenseRegistry.reset();
  registerThirdPartyLicenses(platform: platform, flavor: flavor);
  return LicenseRegistry.licenses.toList();
}

String _text(LicenseEntry entry) =>
    entry.paragraphs.map((p) => p.text).join('\n');

LicenseEntry? _entryFor(List<LicenseEntry> entries, String package) {
  final found = entries.where((e) => e.packages.contains(package)).toList();
  return found.isEmpty ? null : found.single;
}

/// The `#### <name> <version>` headings of one `## ` section of
/// THIRD_PARTY_NOTICES.md.
List<String> _noticeHeadings(String section) {
  final lines = File('THIRD_PARTY_NOTICES.md').readAsLinesSync();
  final start = lines.indexOf('## $section');
  expect(
    start,
    isNot(-1),
    reason: 'THIRD_PARTY_NOTICES.md has no "## $section"',
  );
  final headings = <String>[];
  for (final line in lines.skip(start + 1)) {
    if (line.startsWith('## ')) break;
    final m = RegExp(r'^#### `([^`]+)` (\S+)$').firstMatch(line);
    if (m != null) headings.add('${m.group(1)} ${m.group(2)}');
  }
  return headings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(LicenseRegistry.reset);

  final rust = _readJson('assets/licenses/rust_licenses.json');
  final native = _readJson('assets/licenses/native_licenses.json');
  final crates = (rust['crates'] as List).cast<Map<String, dynamic>>();
  final libraries = (native['libraries'] as List).cast<Map<String, dynamic>>();

  test('the Tor stack is on the licence page, with the plugin under its MIT '
      'licence from Foundation Devices', () async {
    final entries = await _entries();
    for (final crate in ['arti-client', 'tor-rtcompat', 'tokio']) {
      expect(_entryFor(entries, crate), isNotNull, reason: crate);
    }
    final tor = _entryFor(entries, 'tor');
    expect(tor, isNotNull);
    expect(_text(tor!), contains('MIT'));
    expect(_text(tor), contains('Foundation Devices'));
    expect(
      _text(tor),
      contains('Permission is hereby granted, free of charge'),
    );
  });

  test('every MPL-2.0 crate names its crates.io source, in the asset and on '
      'the page', () async {
    final mpl = crates
        .where((c) => (c['licenses'] as List).any((l) => l['id'] == 'MPL-2.0'))
        .toList();
    expect(mpl, isNotEmpty);
    final entries = await _entries();
    for (final crate in mpl) {
      final source =
          'https://crates.io/crates/${crate['name']}/${crate['version']}';
      expect(crate['source'], source);
      expect(
        _text(_entryFor(entries, crate['name'] as String)!),
        contains('Source: $source'),
      );
    }
  });

  test('only the four shipped Rust targets are scanned', () async {
    expect(rust['targets'], [
      'aarch64-apple-ios',
      'aarch64-linux-android',
      'armv7-linux-androideabi',
      'x86_64-linux-android',
    ]);
    final names = crates.map((c) => c['name']).toSet();
    for (final absent in ['r-efi', 'windows-sys', 'windows-targets', 'wasi']) {
      expect(names, isNot(contains(absent)));
    }
    for (final platform in TargetPlatform.values) {
      final entries = await _entries(platform: platform);
      for (final absent in ['r-efi', 'windows-sys']) {
        expect(_entryFor(entries, absent), isNull);
      }
    }
  });

  test('every crate is under an accepted licence, and an OR is recorded as '
      'the option chosen', () {
    const accepted = {
      'MIT',
      'Apache-2.0',
      'BSD-2-Clause',
      'BSD-3-Clause',
      'ISC',
      'Zlib',
      'Unicode-3.0',
      'CC0-1.0',
      'Unlicense',
      'MPL-2.0',
    };
    final texts = (rust['texts'] as List).cast<String>();
    for (final crate in crates) {
      final licenses = (crate['licenses'] as List).cast<Map<String, dynamic>>();
      expect(licenses, isNotEmpty, reason: crate['name'] as String);
      // `also`: the other licences one text is (a file that reproduces
      // several, as aws-lc-sys's LICENSE does).
      List<String> ids(Map<String, dynamic> l) => [
        l['id'] as String,
        ...((l['also'] as List?) ?? const []).cast<String>(),
      ];
      for (final license in licenses) {
        for (final id in ids(license)) {
          expect(accepted, contains(id), reason: crate['name'] as String);
        }
        expect(texts[license['text'] as int], isNotEmpty);
      }
      expect(crate['license'], licenses.expand(ids).toSet().join(' AND '));
    }
    final dunce = crates.singleWhere((c) => c['name'] == 'dunce');
    expect(dunce['expression'], 'CC0-1.0 OR MIT-0 OR Apache-2.0');
    expect(dunce['license'], 'CC0-1.0');
    final awsLc = crates.singleWhere((c) => c['name'] == 'aws-lc-sys');
    expect(
      (awsLc['license'] as String).split(' AND ').toSet(),
      {'Apache-2.0', 'BSD-3-Clause', 'ISC', 'MIT'},
    );
  });

  test(
    'the Android libraries plugins pull in are listed, androidx included',
    () async {
      expect(libraries, isNotEmpty);
      final entries = await _entries();
      final androidx = entries
          .where((e) => e.packages.any((p) => p.startsWith('androidx.')))
          .toList();
      expect(androidx, isNotEmpty);
      expect(_text(androidx.first), contains('Apache License'));
    },
  );

  test('store-only libraries appear only in the store build, and none on '
      'iOS', () async {
    final storeOnly = libraries.where((l) => l['flavor'] == 'store').toList();
    expect(
      storeOnly.map((l) => l['coordinate']),
      contains('com.android.billingclient:billing'),
    );
    final direct = await _entries();
    final store = await _entries(flavor: 'store');
    bool lists(List<LicenseEntry> es, String coordinate) =>
        es.any((e) => _text(e).contains(coordinate));
    for (final lib in storeOnly) {
      expect(
        lists(direct, lib['coordinate'] as String),
        isFalse,
        reason: '${lib['coordinate']} must not be listed in the direct build',
      );
      expect(lists(store, lib['coordinate'] as String), isTrue);
    }
    final ios = await _entries(platform: TargetPlatform.iOS, flavor: 'store');
    expect(
      ios.where((e) => e.packages.any((p) => p.startsWith('androidx.'))),
      isEmpty,
    );
  });

  test(
    'a crate built for one platform only is shown on that platform only',
    () async {
      final android = await _entries();
      final ios = await _entries(platform: TargetPlatform.iOS);
      expect(_entryFor(android, 'jni'), isNotNull);
      expect(_entryFor(ios, 'jni'), isNull);
      expect(_entryFor(ios, 'oslog'), isNotNull);
      expect(_entryFor(android, 'oslog'), isNull);
      expect(_entryFor(android, 'arti-client'), isNotNull);
      expect(_entryFor(ios, 'arti-client'), isNotNull);
    },
  );

  test(
    'each package appears in exactly one entry, and every entry renders',
    () async {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        for (final flavor in ['direct', 'store']) {
          final entries = await _entries(platform: platform, flavor: flavor);
          final packages = [for (final e in entries) ...e.packages];
          expect(
            packages.toSet().length,
            packages.length,
            reason: '$platform $flavor',
          );
          for (final entry in entries) {
            // What the licence page does with an entry: parse its paragraphs.
            expect(entry.paragraphs, isNotEmpty, reason: '${entry.packages}');
          }
        }
      }
    },
  );

  test('THIRD_PARTY_NOTICES.md lists exactly the crates of the asset', () {
    expect(File('THIRD_PARTY_NOTICES.md').existsSync(), isTrue);
    final fromAsset = [for (final c in crates) '${c['name']} ${c['version']}'];
    expect(_noticeHeadings('Rust crates'), fromAsset);
  });

  test(
    'the Rust standard library is listed, at the toolchain the fork pins',
    () async {
      final toolchain = (rust['toolchain'] as List)
          .cast<Map<String, dynamic>>();
      // The release check ties this version to the workflow's RUST_TOOLCHAIN,
      // and the generator to the fork's rust/rust-toolchain.
      expect(toolchain.single['version'], matches(RegExp(r'^\d+\.\d+\.\d+$')));
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        final std = _entryFor(
          await _entries(platform: platform),
          'Rust standard library',
        );
        expect(std, isNotNull);
        expect(_text(std!), contains('MIT OR Apache-2.0, used under MIT'));
        expect(
          _text(std),
          contains('Copyright (c) The Rust Project Contributors'),
        );
      }
    },
  );

  test('a crate whose package has no licence file gets its repository\'s, '
      'and its notices ship with it', () async {
    final frb = crates.singleWhere((c) => c['name'] == 'flutter_rust_bridge');
    expect(frb['licenses'][0]['origin'], startsWith('https://'));
    final entries = await _entries();
    expect(
      _text(_entryFor(entries, 'flutter_rust_bridge')!),
      contains('Copyright (c) 2021 fzyzcjy'),
    );
    final rand = crates.firstWhere((c) => c['name'] == 'rand');
    expect(rand['notices'], isNotEmpty);
    expect(
      _text(_entryFor(entries, 'rand')!),
      contains('Copyrights in the Rand project are retained by their'),
    );
  });

  test('the Material Icons font Flutter bundles is credited (CC BY 4.0, '
      'Google), on both platforms', () async {
    final flutter = File('.flutter-version').readAsStringSync().trim();
    final fonts = (native['fonts'] as List).cast<Map<String, dynamic>>();
    expect(fonts.map((f) => f['asset']), ['fonts/MaterialIcons-Regular.otf']);
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final flavor in ['direct', 'store']) {
        final entries = await _entries(platform: platform, flavor: flavor);
        final font = _entryFor(entries, 'Material Icons font');
        expect(font, isNotNull, reason: '$platform $flavor');
        expect(_text(font!), contains('bundled by Flutter $flutter'));
        expect(_text(font), contains('© Google'));
        expect(_text(font), contains('CC-BY-4.0'));
        expect(_text(font), contains('Attribution 4.0 International'));
        expect(
          _text(font),
          contains('https://github.com/google/material-design-icons'),
        );
      }
    }
    final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    expect(
      notices,
      contains('Material Icons font (bundled by Flutter $flutter)'),
    );
    expect(notices, isNot(contains('Bag ships no font')));
  });

  test('a copyright line from another of a crate\'s licence files ships, and '
      'a flag says which case it is', () async {
    final entries = await _entries();
    expect(
      _text(_entryFor(entries, 'num_enum')!),
      contains('Copyright (c) 2018, Daniel Wagner-Hall'),
    );
    final numEnum = crates.singleWhere((c) => c['name'] == 'num_enum');
    expect(
      (numEnum['notes'] as List? ?? []).join(' '),
      isNot(contains('Flagged')),
    );
    const flags = {
      'Flagged: no licence file in its package names a copyright holder.',
      'Flagged: the package ships no licence file.',
    };
    const reviewed =
        "Flagged: its licence files name no holder of the crate's own code "
        '(third-party notice reviewed: ';
    for (final crate in crates) {
      final flagged = (crate['notes'] as List? ?? [])
          .cast<String>()
          .where((n) => n.startsWith('Flagged'))
          .where((n) => !n.startsWith(reviewed));
      expect(flags, containsAll(flagged), reason: crate['name'] as String);
    }
    // A derived work's holder counts, mid-line and with the year on the
    // next line (hashlink's MIT text).
    final hashlink = crates.singleWhere((c) => c['name'] == 'hashlink');
    expect(
      (hashlink['notes'] as List? ?? []).join(' '),
      isNot(contains('Flagged')),
    );
    final lexical = crates.singleWhere((c) => c['name'] == 'minimal-lexical');
    expect((lexical['notes'] as List).join(' '), contains(reviewed));
  });

  test(
    'desugar_jdk_libs names its source, in the asset and on the page',
    () async {
      final desugar = libraries.singleWhere(
        (l) => l['coordinate'] == 'com.android.tools:desugar_jdk_libs',
      );
      expect(
        desugar['source'],
        startsWith('https://github.com/google/desugar_jdk_libs/tree/'),
      );
      final entries = await _entries();
      expect(
        _text(_entryFor(entries, 'com.android.tools')!),
        contains('Source: ${desugar['source']}'),
      );
      expect(
        File('THIRD_PARTY_NOTICES.md').readAsStringSync(),
        contains('Source: ${desugar['source']}'),
      );
    },
  );

  test(
    'no licence text carries a template copyright line nobody filled in',
    () {
      // `Copyright (c) <year> <copyright holders>`, `… [year] [fullname]`,
      // `… {yyyy} {name}`. An Apache License's appendix (after its terms) has
      // its own `Copyright [yyyy] [name of copyright owner]`, which is
      // licence text, so only the terms are checked; and a placeholder
      // outside a copyright line (a template's `<COPYRIGHT HOLDER>` left in a
      // disclaimer) is licence text.
      final placeholder = RegExp(
        r'<\s*(year|yyyy|copyright holders?|owner|fullname|name of [^>]*)\s*>'
        r'|\[\s*(yyyy|year|fullname|owner)\s*\]'
        r'|\{\s*(yyyy|year|copyright holders?|owner|fullname|name|name of [^}]*)\s*\}',
        caseSensitive: false,
      );
      final copyrightLine = RegExp(
        r'^\s*(copyright\b|\(c\)|©)',
        caseSensitive: false,
      );
      String terms(String text) =>
          text.split('END OF TERMS AND CONDITIONS').first;
      final texts = <String, String>{
        for (final (i, t) in (rust['texts'] as List).cast<String>().indexed)
          'rust text $i': t,
        for (final MapEntry(:key, :value)
            in (native['texts'] as Map).cast<String, String>().entries)
          'native text $key': value,
        for (final (i, block)
            in File('THIRD_PARTY_NOTICES.md')
                .readAsStringSync()
                .split(RegExp(r'^````text$', multiLine: true))
                .skip(1)
                .indexed)
          'THIRD_PARTY_NOTICES.md block $i': block.split('````').first,
      };
      final found = [
        for (final MapEntry(:key, :value) in texts.entries)
          for (final line in terms(value).split('\n'))
            if (copyrightLine.hasMatch(line) && placeholder.hasMatch(line))
              '$key: $line',
      ];
      expect(found, isEmpty);
    },
  );

  test('THIRD_PARTY_NOTICES.md says what Bag is licensed under and where its '
      'source is', () {
    final head = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    expect(head, contains('GPL-3.0-only'));
    expect(head, contains('https://github.com/UXAVIA/bag'));
  });

  test('the assets are declared, so the release build carries them', () async {
    for (final path in [
      'assets/licenses/rust_licenses.json',
      'assets/licenses/native_licenses.json',
    ]) {
      expect(await rootBundle.loadString(path), isNotEmpty, reason: path);
    }
  });
}
