part of 'wallet_engine.dart';

/// Uniform address supply for the gap-limit scanner.
///
/// The scanner does not care whether addresses come from a single BIP84 zpub
/// or a multisig output descriptor — it only asks for "the address at chain
/// [chain], index [index]". Implementations cache the chain-level derivation
/// so a scan costs one EC point multiplication per address per key rather
/// than two.
///
/// No implementation logs keys, scripts or addresses.
abstract interface class AddressSource {
  /// Chains this source can produce. 0 = external/receive, 1 = change.
  /// A receive-only descriptor reports only chain 0.
  bool hasChain(int chain);

  /// Returns the address at [chain] / [index].
  /// Throws [Bip32InvalidChildException] if the derived child is invalid —
  /// per BIP32 the caller skips that index.
  String addressAt(int chain, int index);
}

/// Single-sig BIP84 (`zpub`) address source — P2WPKH, chains 0 and 1.
final class ZpubAddressSource implements AddressSource {
  final ZpubKey _root;
  final Map<int, ZpubKey> _chainKeys = {};

  ZpubAddressSource(this._root);

  @override
  bool hasChain(int chain) => chain == 0 || chain == 1;

  @override
  String addressAt(int chain, int index) {
    assert(chain == 0 || chain == 1);
    final chainKey = _chainKeys[chain] ??= deriveChild(_root, chain);
    return pubKeyToP2wpkh(deriveChild(chainKey, index).publicKey);
  }
}

/// Output-descriptor address source — multisig or single key, any of the
/// script types in [DescriptorScriptType].
final class DescriptorAddressSource implements AddressSource {
  final WalletDescriptor descriptor;

  /// chain → per-cosigner chain-level keys, in descriptor order.
  final Map<int, List<ZpubKey>> _chainKeys = {};

  DescriptorAddressSource(this.descriptor);

  /// Maps the logical chain (0 = receive, 1 = change) onto the derivation
  /// index the descriptor actually declares, or null when the descriptor
  /// does not cover that chain.
  int? _declaredIndexFor(int chain) => switch (chain) {
        0 => descriptor.keys.first.receiveChain,
        1 => descriptor.keys.first.changeChain,
        _ => null,
      };

  @override
  bool hasChain(int chain) {
    if (chain == 0) return true; // always at least the receive chain
    if (chain != 1) return false;
    // A change chain exists only when the descriptor declared one.
    return descriptor.keys.first.changeChain != null;
  }

  @override
  String addressAt(int chain, int index) {
    final keys = _chainKeys[chain] ??= _buildChainKeys(chain);

    var pubKeys = [
      for (final k in keys) deriveChild(k, index).publicKey,
    ];

    if (descriptor.isMultisig) {
      if (descriptor.sorted) pubKeys = sortPubKeysBip67(pubKeys);
      final script = buildMultisigScript(descriptor.threshold, pubKeys);
      return switch (descriptor.scriptType) {
        DescriptorScriptType.p2wsh => scriptToP2wsh(script),
        DescriptorScriptType.p2shP2wsh => scriptToP2shWsh(script),
        DescriptorScriptType.p2sh => scriptToP2sh(script),
        // A multi()/sortedmulti() can only appear under wsh/sh; the parser
        // rejects anything else, so these are unreachable.
        _ => throw const DescriptorException(
            'Multisig is only valid inside wsh(...) or sh(...)'),
      };
    }

    final pubKey = pubKeys.single;
    return switch (descriptor.scriptType) {
      DescriptorScriptType.p2wpkh => pubKeyToP2wpkh(pubKey),
      DescriptorScriptType.p2shP2wpkh => pubKeyToP2shWpkh(pubKey),
      DescriptorScriptType.p2pkh => pubKeyToP2pkh(pubKey),
      _ => throw const DescriptorException(
          'Single-key descriptor with an unsupported script type'),
    };
  }

  List<ZpubKey> _buildChainKeys(int chain) {
    final declared = _declaredIndexFor(chain);
    return [
      for (final k in descriptor.keys)
        // A bare `/*` descriptor derives addresses straight off the key.
        declared == null ? k.key : deriveChild(k.key, declared),
    ];
  }
}
