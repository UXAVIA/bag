// Net effect of a mempool transaction on one wallet.
//
// A spend from a watch-only wallet almost always has two outputs: the payee
// and the wallet's own change. Reporting the consumed inputs as "sent" — or
// worse, only the inputs of whichever address happened to be polled first —
// tells the user a large amount left when most of it came straight back.
// The honest figure is the wallet-wide net: outputs to the wallet's own
// addresses minus inputs from them, which is (amount sent + fee) for a spend
// and the amount received for a deposit.
//
// [walletAddresses] must include the wallet's UTXO addresses and its next
// few unused receive *and change* addresses, or the change output would be
// invisible and the spend overstated.

import 'esplora_client.dart';

/// Direction and magnitude of [tx]'s effect on the wallet that owns
/// [walletAddresses]. `sats` is always ≥ 0; `dir` is `'in'` when the wallet
/// gains, otherwise `'out'` (a self-transfer nets to −fee, so it is a spend).
({String dir, int sats}) mempoolNetEffect(
  MempoolTx tx,
  Set<String> walletAddresses,
) {
  var spent = 0;
  for (final i in tx.inputs) {
    if (i.address != null && walletAddresses.contains(i.address)) {
      spent += i.sats;
    }
  }
  var received = 0;
  for (final o in tx.outputs) {
    if (o.address != null && walletAddresses.contains(o.address)) {
      received += o.sats;
    }
  }
  final net = received - spent;
  return (dir: net > 0 ? 'in' : 'out', sats: net.abs());
}
