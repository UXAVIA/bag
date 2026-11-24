/// Wallet-wide net effect of a mempool transaction (Sentinel alerts).
///
/// Regression for a Bitkey 2-of-3 spend: the tx consumed a 100k-sat input,
/// paid 10k and returned ~89k as change. Sentinel used to report whatever the
/// first polled address contributed as inputs — so either "−100k" or, for a
/// second small input, a misleadingly tiny amount — and never subtracted the
/// change. The user should see "−(10k + fee)".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/wallet/tx_effect.dart';

const utxo = 'bc1q_our_utxo';
const utxoSmall = 'bc1q_our_small_utxo';
const change = 'bc1q_our_change_frontier';
const receive = 'bc1q_our_receive_frontier';
const payee = 'bc1q_someone_else';
const stranger = 'bc1q_stranger_input';

final mine = {utxo, utxoSmall, change, receive};

void main() {
  test('spend with change nets to amount + fee, not the consumed input', () {
    final tx = MempoolTx(
      txid: 'a',
      inputs: [(address: utxo, sats: 100000)],
      outputs: [
        (address: payee, sats: 10000),
        (address: change, sats: 89000), // 1k fee
      ],
    );
    expect(mempoolNetEffect(tx, mine), (dir: 'out', sats: 11000));
  });

  test('multiple inputs are all counted, whichever address surfaced it', () {
    final tx = MempoolTx(
      txid: 'b',
      inputs: [(address: utxoSmall, sats: 500), (address: utxo, sats: 100000)],
      outputs: [(address: payee, sats: 10000), (address: change, sats: 89500)],
    );
    expect(mempoolNetEffect(tx, mine), (dir: 'out', sats: 11000));
  });

  test('without the change address watched the spend is overstated', () {
    // Documents why the change frontier belongs in the watch map.
    final tx = MempoolTx(
      txid: 'c',
      inputs: [(address: utxo, sats: 100000)],
      outputs: [(address: payee, sats: 10000), (address: change, sats: 89000)],
    );
    expect(mempoolNetEffect(tx, {utxo}), (dir: 'out', sats: 100000));
  });

  test('incoming payment reports what arrived, ignoring foreign inputs', () {
    final tx = MempoolTx(
      txid: 'd',
      inputs: [(address: stranger, sats: 50000)],
      outputs: [
        (address: receive, sats: 20000),
        (address: null, sats: 29000), // stranger's change, non-standard
      ],
    );
    expect(mempoolNetEffect(tx, mine), (dir: 'in', sats: 20000));
  });

  test('self-transfer / consolidation is a spend of exactly the fee', () {
    final tx = MempoolTx(
      txid: 'e',
      inputs: [(address: utxo, sats: 100000), (address: utxoSmall, sats: 500)],
      outputs: [(address: receive, sats: 100200)],
    );
    expect(mempoolNetEffect(tx, mine), (dir: 'out', sats: 300));
  });

  test('a transaction touching none of our addresses nets to zero', () {
    final tx = MempoolTx(
      txid: 'f',
      inputs: [(address: stranger, sats: 1)],
      outputs: [(address: payee, sats: 1)],
    );
    expect(mempoolNetEffect(tx, mine), (dir: 'out', sats: 0));
  });
}
