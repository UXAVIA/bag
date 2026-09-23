/// Gap-limit scanner against a fake Esplora client.
///
/// Guards the change-chain behaviour that a receive-only descriptor silently
/// breaks: a wallet whose descriptor covers only `/0/*` never has its change
/// addresses queried, so after a spend the balance drops by the whole
/// consumed input. Pasting Bitkey's full export (External + Internal) must
/// scan chain 1 and count the change.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/wallet/wallet_engine.dart';
import 'package:bag/services/wallet/wallet_scanner.dart';

const _xpub1 =
    'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8';
const _xpub2 =
    'xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB';

/// Answers from a fixed address → balance map; everything else is unused.
final class _FakeEsplora extends EsploraClient {
  final Map<String, int> balances;
  final queried = <String>[];

  _FakeEsplora(this.balances) : super(baseUrl: 'http://unused.invalid');

  @override
  Future<AddressStats> fetchAddress(String address) async {
    queried.add(address);
    final sats = balances[address];
    return AddressStats(hasTransactions: sats != null, balanceSats: sats ?? 0);
  }
}

void main() {
  final full = parseDescriptor(
    'External: wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))\n'
    'Internal: wsh(sortedmulti(2,$_xpub1/1/*,$_xpub2/1/*))',
  );
  final receiveOnly = parseDescriptor(
    'wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))',
  );

  // Simulate "received 100k on receive #0, spent 10k, change 89k to change #0".
  final ref = DescriptorAddressSource(full);
  final receive0 = ref.addressAt(0, 0);
  final change0 = ref.addressAt(1, 0);
  final chain = {receive0: 0, change0: 89000}; // receive #0 fully spent

  test('full export counts change on chain 1', () async {
    final client = _FakeEsplora(chain);
    final balance = await scanWallet(DescriptorAddressSource(full), client);
    expect(balance.totalSats, 89000);
    expect(balance.usedAddressCount, 2);
    expect(balance.lastChangeIndex, 0);
    // Sentinel's frontier starts at the first unused index on each chain.
    expect(balance.nextExternalIndex, 1);
    expect(balance.nextChangeIndex, 1);
    expect(balance.utxoAddresses, [change0]);
    expect(client.queried, contains(change0));
  });

  test(
    'receive-only descriptor never touches chain 1 and misses change',
    () async {
      final client = _FakeEsplora(chain);
      final balance = await scanWallet(
        DescriptorAddressSource(receiveOnly),
        client,
      );
      expect(balance.totalSats, 0);
      expect(client.queried, isNot(contains(change0)));
      expect(balance.nextChangeIndex, 0); // no change chain at all
      // Every queried address is a receive address.
      final receiveAddresses = List.generate(
        client.queried.length,
        (i) => ref.addressAt(0, i),
      );
      expect(client.queried, receiveAddresses);
    },
  );

  test('an empty wallet reports index 0 as the next unused, not 1', () async {
    final client = _FakeEsplora({});
    final balance = await scanWallet(DescriptorAddressSource(full), client);
    expect(balance.lastExternalIndex, 0); // legacy: 0 also means "none"
    expect(balance.nextExternalIndex, 0);
    expect(balance.nextChangeIndex, 0);
  });

  test('gap limit: stops 20 unused addresses past the last used one', () async {
    final client = _FakeEsplora({ref.addressAt(0, 5): 1});
    await scanWallet(DescriptorAddressSource(receiveOnly), client);
    // Batches of 4 over clearnet: indices 0..27 cover 5 + 20 gap (=26).
    expect(client.queried.length, 28);
    expect(client.queried, isNot(contains(ref.addressAt(0, 28))));
  });
}
