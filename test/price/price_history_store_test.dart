/// M-10: the historical-price cache records every date the DCA sheet looked
/// up, so it lives in its own encrypted Hive box, not in the plaintext
/// `price_cache` box. Hive encrypts values only (keys are written in the
/// clear), so the dates are inside the encrypted value, never in a key.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/services/dca_store.dart';
import 'package:bag/services/price_history_store.dart';
import 'package:bag/services/price_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    hiveDir = await Directory.systemTemp.createTemp('price_hist_store');
    Hive.init(hiveDir.path);
    await Hive.openBox<String>(AppConstants.priceBox);
  });

  tearDown(() async {
    PriceHistoryStore.debugReset();
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  File boxFile(String name) => File('${hiveDir.path}/$name.hive');

  bool fileMentions(String name, String needle) {
    final file = boxFile(name);
    if (!file.existsSync()) return false;
    return latin1.decode(file.readAsBytesSync()).contains(needle);
  }

  test('legacy hist_ entries move to the encrypted box, then leave the '
      'plaintext file', () async {
    final plain = Hive.box<String>(AppConstants.priceBox);
    await plain.put('hist_usd_2024-03-01', '62000.5');
    await plain.put('hist_eur_2023-11-30', '35000.0');
    await plain.put('${AppConstants.chartKeyPrefix}usd_7', '[1,2]');
    await plain.put(AppConstants.priceKey, '{"spot":1}');
    await plain.flush();
    expect(fileMentions(AppConstants.priceBox, '2024-03-01'), isTrue);

    await PriceHistoryStore.open();

    expect(PriceHistoryStore.read('usd', DateTime(2024, 3, 1)), 62000.5);
    expect(PriceHistoryStore.read('eur', DateTime(2023, 11, 30)), 35000.0);
    // Spot and chart data stay where they are.
    expect(plain.get('${AppConstants.chartKeyPrefix}usd_7'), '[1,2]');
    expect(plain.get(AppConstants.priceKey), '{"spot":1}');
    expect(plain.keys.where((k) => '$k'.startsWith('hist_')), isEmpty);

    await Hive.close();
    // Deleted frames stay in a Hive file until it is compacted: the dates
    // must be gone from the bytes, not only from the key set.
    expect(fileMentions(AppConstants.priceBox, '2024-03-01'), isFalse);
    expect(fileMentions(AppConstants.priceBox, '2023-11-30'), isFalse);
    // And the encrypted box carries no date in a key either.
    expect(boxFile(AppConstants.priceHistoryBox).existsSync(), isTrue);
    expect(fileMentions(AppConstants.priceHistoryBox, '2024-03-01'), isFalse);
    expect(fileMentions(AppConstants.priceHistoryBox, '2023-11-30'), isFalse);
    expect(fileMentions(AppConstants.priceHistoryBox, '62000'), isFalse);
  });

  test('entries survive a restart, and a second open migrates nothing',
      () async {
    final plain = Hive.box<String>(AppConstants.priceBox);
    await plain.put('hist_usd_2024-03-01', '62000.5');
    await PriceHistoryStore.open();
    await PriceHistoryStore.write('gbp', DateTime(2022, 1, 5), 30000);

    await Hive.close();
    PriceHistoryStore.debugReset();
    await Hive.openBox<String>(AppConstants.priceBox);
    await PriceHistoryStore.open();

    expect(PriceHistoryStore.read('usd', DateTime(2024, 3, 1)), 62000.5);
    expect(PriceHistoryStore.read('gbp', DateTime(2022, 1, 5)), 30000);
    expect(PriceHistoryStore.read('gbp', DateTime(2022, 1, 6)), isNull);
  });

  test('fetchHistoricalPrice answers from the encrypted box and writes '
      'nothing to the plaintext one', () async {
    await PriceHistoryStore.open();
    await PriceHistoryStore.write('usd', DateTime(2024, 3, 1), 62000.5);

    final price = await PriceService(route: const DirectRoute())
        .fetchHistoricalPrice('usd', DateTime(2024, 3, 1));

    expect(price, 62000.5);
    final plain = Hive.box<String>(AppConstants.priceBox);
    expect(plain.keys.where((k) => '$k'.startsWith('hist_')), isEmpty);
  });

  test('an encrypted box that cannot open leaves the DCA box and the legacy '
      'entries alone, and never throws', () async {
    // A real DCA log, opened the way main() does, before the history box.
    await openEncryptedDcaBox();
    final dca = Hive.box<String>(AppConstants.dcaBoxEncrypted);
    await dca.put('entry-1', '{"btcAmount":0.1}');

    final plain = Hive.box<String>(AppConstants.priceBox);
    await plain.put('hist_usd_2024-03-01', '62000.5');
    // Something the box can't be opened over.
    Directory('${hiveDir.path}/${AppConstants.priceHistoryBox}.hive')
        .createSync();

    await PriceHistoryStore.open();

    expect(PriceHistoryStore.isOpen, isFalse);
    expect(PriceHistoryStore.read('usd', DateTime(2024, 3, 1)), isNull);
    // Kept for the next launch's migration rather than lost.
    expect(plain.get('hist_usd_2024-03-01'), '62000.5');
    // The DCA log is untouched and still readable.
    expect(dca.isOpen, isTrue);
    expect(dca.get('entry-1'), '{"btcAmount":0.1}');
    // A write without the box goes nowhere, least of all to plaintext.
    await PriceHistoryStore.write('usd', DateTime(2024, 3, 2), 1);
    expect(plain.keys.where((k) => '$k'.contains('2024-03-02')), isEmpty);

    // The DCA box reopens with its own key afterwards.
    await dca.close();
    await openEncryptedDcaBox();
    expect(
      Hive.box<String>(AppConstants.dcaBoxEncrypted).get('entry-1'),
      '{"btcAmount":0.1}',
    );
  });

  test('the history box has its own key, so it can never replace the DCA '
      'key', () async {
    await openEncryptedDcaBox();
    await PriceHistoryStore.open();
    const storage = FlutterSecureStorage();
    final all = await storage.readAll();
    expect(all.keys, containsAll(['dca_box_key', 'price_hist_box_key']));
    expect(all['dca_box_key'], isNot(all['price_hist_box_key']));
  });
}
