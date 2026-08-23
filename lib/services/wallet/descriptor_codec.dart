part of 'wallet_engine.dart';

/// Output-descriptor parsing (BIP380/381/383/384/389) for watch-only wallets.
///
/// Covers what hardware wallets and coordinators actually export for a
/// watch-only multisig — Bitkey, Sparrow, Nunchuk, Blue Wallet, Bitcoin Core:
///
///   wsh(sortedmulti(2,[fp/48h/0h/0h/2h]xpub…/<0;1>/*,…))#checksum   ← Bitkey
///   sh(wsh(sortedmulti(2,…)))                                       nested
///   sh(sortedmulti(2,…))                                            legacy
///   wpkh([fp/84h/0h/0h]xpub…/<0;1>/*)                               single-sig
///   sh(wpkh(…)) / pkh(…)
///
/// Security invariants:
/// - Only *public* key material is accepted. Any xprv/yprv/zprv prefix is
///   rejected with an explicit error before anything else is parsed.
/// - The BIP380 checksum is verified when present — a single mistyped
///   character in a pasted descriptor is caught rather than silently
///   producing a wrong (and unmonitored) address set.
/// - Hardened steps after the extended key are rejected: they cannot be
///   derived from a public key, and silently skipping them would produce
///   addresses the user does not actually own.
/// - The descriptor string is NEVER logged, and neither are derived addresses.

/// Script type a descriptor resolves to.
enum DescriptorScriptType {
  /// `wsh(...)` — native segwit script hash. Bitkey and every modern multisig.
  p2wsh,

  /// `sh(wsh(...))` — nested segwit script hash.
  p2shP2wsh,

  /// `sh(...)` — legacy P2SH.
  p2sh,

  /// `wpkh(...)` — native segwit single key.
  p2wpkh,

  /// `sh(wpkh(...))` — nested segwit single key.
  p2shP2wpkh,

  /// `pkh(...)` — legacy single key.
  p2pkh,
}

/// Thrown when a descriptor string fails any validation step.
/// The message is safe to show to the user — it never echoes the input.
final class DescriptorException implements Exception {
  final String message;
  const DescriptorException(this.message);

  @override
  String toString() => 'DescriptorException: $message';
}

/// One key expression inside a descriptor, with the chain indices its
/// derivation suffix declares.
final class DescriptorKey {
  final ZpubKey key;

  /// Index used for the receive chain, or null when the descriptor derives
  /// addresses directly from [key] (a bare `/*` suffix).
  final int? receiveChain;

  /// Index used for the change chain, or null when the descriptor covers
  /// only one chain (e.g. a receive-only `/0/*` export).
  final int? changeChain;

  const DescriptorKey({
    required this.key,
    required this.receiveChain,
    required this.changeChain,
  });
}

/// A parsed, validated output descriptor.
final class WalletDescriptor {
  final DescriptorScriptType scriptType;

  /// Signatures required. 1 for single-key descriptors.
  final int threshold;

  /// True for `sortedmulti` (BIP67 lexicographic key ordering).
  final bool sorted;

  /// True when the descriptor is a multisig (`multi` / `sortedmulti`).
  final bool isMultisig;

  final List<DescriptorKey> keys;

  const WalletDescriptor({
    required this.scriptType,
    required this.threshold,
    required this.sorted,
    required this.isMultisig,
    required this.keys,
  });

  /// e.g. "2-of-3 multisig · native segwit".
  String get summary {
    final script = switch (scriptType) {
      DescriptorScriptType.p2wsh || DescriptorScriptType.p2wpkh =>
        'native segwit',
      DescriptorScriptType.p2shP2wsh || DescriptorScriptType.p2shP2wpkh =>
        'nested segwit',
      DescriptorScriptType.p2sh || DescriptorScriptType.p2pkh => 'legacy',
    };
    if (!isMultisig) return 'single key · $script';
    return '$threshold-of-${keys.length} multisig · $script';
  }
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Parses and strictly validates an output descriptor.
/// Throws [DescriptorException] for any invalid input. Never logs the input.
WalletDescriptor parseDescriptor(String raw) {
  // Descriptors are frequently pasted with newlines/indentation from a QR
  // scan or a text export. Whitespace is never significant inside one.
  var input = raw.replaceAll(RegExp(r'\s'), '');
  if (input.isEmpty) throw const DescriptorException('Descriptor is empty');

  input = _verifyAndStripChecksum(input);

  // A multipath descriptor exported as two lines joined by a newline would
  // have collapsed above; reject anything that still looks like two
  // descriptors so we never silently monitor only the first half.
  if (input.contains(')wsh(') ||
      input.contains(')sh(') ||
      input.contains(')wpkh(')) {
    throw const DescriptorException(
        'Multiple descriptors found — paste one descriptor at a time');
  }

  if (input.startsWith('tr(')) {
    throw const DescriptorException(
        'Taproot (tr) descriptors are not supported yet');
  }
  if (input.startsWith('combo(') || input.startsWith('addr(') ||
      input.startsWith('raw(')) {
    throw const DescriptorException(
        'Unsupported descriptor type — use wsh, sh, wpkh or pkh');
  }

  // ── Peel wrappers ──────────────────────────────────────────────────────
  if (_isFunc(input, 'wsh')) {
    final inner = _funcArgs(input, 'wsh');
    return _parseMulti(inner, DescriptorScriptType.p2wsh);
  }

  if (_isFunc(input, 'sh')) {
    final inner = _funcArgs(input, 'sh');
    if (_isFunc(inner, 'wsh')) {
      return _parseMulti(
          _funcArgs(inner, 'wsh'), DescriptorScriptType.p2shP2wsh);
    }
    if (_isFunc(inner, 'wpkh')) {
      return _parseSingle(
          _funcArgs(inner, 'wpkh'), DescriptorScriptType.p2shP2wpkh);
    }
    return _parseMulti(inner, DescriptorScriptType.p2sh);
  }

  if (_isFunc(input, 'wpkh')) {
    return _parseSingle(
        _funcArgs(input, 'wpkh'), DescriptorScriptType.p2wpkh);
  }

  if (_isFunc(input, 'pkh')) {
    return _parseSingle(_funcArgs(input, 'pkh'), DescriptorScriptType.p2pkh);
  }

  throw const DescriptorException(
      'Unrecognised descriptor — expected wsh(...), sh(...), wpkh(...) '
      'or pkh(...)');
}

// ── Script assembly ──────────────────────────────────────────────────────────

/// Builds the bare multisig script `OP_m <pk>… OP_n OP_CHECKMULTISIG`.
/// [pubKeys] must already be in final order (sorted by the caller for
/// `sortedmulti`).
Uint8List buildMultisigScript(int threshold, List<Uint8List> pubKeys) {
  if (threshold < 1 || threshold > 16) {
    throw const DescriptorException('Threshold must be between 1 and 16');
  }
  if (pubKeys.isEmpty || pubKeys.length > 16) {
    throw const DescriptorException('Multisig supports 1–16 keys');
  }
  if (threshold > pubKeys.length) {
    throw const DescriptorException(
        'Threshold cannot exceed the number of keys');
  }

  final out = BytesBuilder();
  out.addByte(0x50 + threshold); // OP_1 … OP_16
  for (final pk in pubKeys) {
    if (pk.length != 33) {
      throw const DescriptorException('Expected compressed public keys');
    }
    out.addByte(0x21); // push 33 bytes
    out.add(pk);
  }
  out.addByte(0x50 + pubKeys.length); // OP_1 … OP_16
  out.addByte(0xae); // OP_CHECKMULTISIG
  return out.toBytes();
}

/// BIP67 lexicographic ordering of compressed public keys.
List<Uint8List> sortPubKeysBip67(List<Uint8List> keys) {
  final copy = [...keys];
  copy.sort(_compareBytes);
  return copy;
}

int _compareBytes(Uint8List a, Uint8List b) {
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

// ── Internals: structure ─────────────────────────────────────────────────────

bool _isFunc(String s, String name) =>
    s.startsWith('$name(') && s.endsWith(')');

/// Returns the argument text inside `name(...)`, verifying balanced
/// parentheses so `wsh(a)junk(b)` is rejected rather than truncated.
String _funcArgs(String s, String name) {
  final body = s.substring(name.length + 1, s.length - 1);
  var depth = 0;
  for (final unit in body.codeUnits) {
    if (unit == 0x28) depth++; // (
    if (unit == 0x29) {
      depth--;
      if (depth < 0) throw const DescriptorException('Malformed descriptor');
    }
  }
  if (depth != 0) throw const DescriptorException('Malformed descriptor');
  return body;
}

WalletDescriptor _parseMulti(String inner, DescriptorScriptType type) {
  final bool sorted;
  final String args;
  if (_isFunc(inner, 'sortedmulti')) {
    sorted = true;
    args = _funcArgs(inner, 'sortedmulti');
  } else if (_isFunc(inner, 'multi')) {
    sorted = false;
    args = _funcArgs(inner, 'multi');
  } else {
    throw const DescriptorException(
        'Only multi / sortedmulti scripts are supported inside wsh/sh');
  }

  final parts = _splitTopLevel(args);
  if (parts.length < 2) {
    throw const DescriptorException('Multisig descriptor has no keys');
  }

  final threshold = int.tryParse(parts.first);
  if (threshold == null) {
    throw const DescriptorException('Multisig threshold is not a number');
  }

  final keys = parts.skip(1).map(_parseKeyExpression).toList();
  if (threshold < 1 || threshold > keys.length) {
    throw DescriptorException(
        'Invalid threshold $threshold for ${keys.length} keys');
  }
  if (keys.length > 16) {
    throw const DescriptorException('Multisig supports at most 16 keys');
  }
  _requireConsistentChains(keys);

  return WalletDescriptor(
    scriptType: type,
    threshold: threshold,
    sorted: sorted,
    isMultisig: true,
    keys: keys,
  );
}

WalletDescriptor _parseSingle(String inner, DescriptorScriptType type) {
  final key = _parseKeyExpression(inner);
  return WalletDescriptor(
    scriptType: type,
    threshold: 1,
    sorted: false,
    isMultisig: false,
    keys: [key],
  );
}

/// Splits a comma-separated argument list, ignoring commas nested inside
/// `[...]`, `(...)` or `<...>`.
List<String> _splitTopLevel(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  var depth = 0;
  for (final ch in s.split('')) {
    switch (ch) {
      case '(':
      case '[':
      case '<':
        depth++;
        buf.write(ch);
      case ')':
      case ']':
      case '>':
        depth--;
        buf.write(ch);
      case ',':
        if (depth == 0) {
          out.add(buf.toString());
          buf.clear();
        } else {
          buf.write(ch);
        }
      default:
        buf.write(ch);
    }
  }
  out.add(buf.toString());
  return out;
}

/// Every key in a multisig must cover the same chains, otherwise the derived
/// scripts would mix chains across cosigners and produce addresses nobody owns.
void _requireConsistentChains(List<DescriptorKey> keys) {
  final first = keys.first;
  for (final k in keys.skip(1)) {
    if (k.receiveChain != first.receiveChain ||
        k.changeChain != first.changeChain) {
      throw const DescriptorException(
          'Cosigner keys use different derivation paths — '
          'export the descriptor again from your wallet');
    }
  }
}

// ── Internals: key expressions ───────────────────────────────────────────────

/// Parses `[fingerprint/origin]XPUB/derivation` into a [DescriptorKey].
///
/// The key origin (the `[...]` prefix) is metadata only: it records how the
/// signer reached this xpub from its seed. Those steps are hardened and
/// therefore already baked into the xpub — we intentionally ignore them.
DescriptorKey _parseKeyExpression(String raw) {
  var expr = raw;

  // Strip the optional key-origin prefix.
  if (expr.startsWith('[')) {
    final close = expr.indexOf(']');
    if (close < 0) {
      throw const DescriptorException('Malformed key origin in descriptor');
    }
    expr = expr.substring(close + 1);
  }

  if (expr.isEmpty) {
    throw const DescriptorException('Descriptor contains an empty key');
  }

  // Split the extended key from its derivation suffix.
  final slash = expr.indexOf('/');
  final keyPart = slash < 0 ? expr : expr.substring(0, slash);
  final suffix = slash < 0 ? '' : expr.substring(slash + 1);

  if (keyPart.length < 4) {
    throw const DescriptorException('Descriptor contains an invalid key');
  }

  // Reject raw (non-extended) public keys outright: they produce a single
  // fixed address, which would silently under-report the wallet balance.
  if (!RegExp(r'^[xyzYZ]pub').hasMatch(keyPart)) {
    final privateError = _privateKeyPrefixError(keyPart);
    if (privateError != null) throw DescriptorException(privateError.message);
    throw const DescriptorException(
        'Descriptor keys must be extended public keys (xpub/ypub/zpub)');
  }

  final ZpubKey key;
  try {
    key = parseExtendedPubKey(keyPart);
  } on ZpubException catch (e) {
    throw DescriptorException(e.message);
  }

  final (receive, change) = _parseDerivationSuffix(suffix);
  return DescriptorKey(
    key: key,
    receiveChain: receive,
    changeChain: change,
  );
}

/// Interprets the derivation suffix that follows an extended key.
///
/// Accepted forms:
///   `<0;1>/*`  → receive chain 0, change chain 1 (BIP389 multipath)
///   `0/*`      → receive-only descriptor on chain 0
///   `1/*`      → change-only descriptor
///   `*`        → addresses derived directly from the key, single chain
///   ``         → same as `*`
(int?, int?) _parseDerivationSuffix(String suffix) {
  if (suffix.isEmpty || suffix == '*') return (null, null);

  if (!suffix.endsWith('/*')) {
    if (suffix.endsWith('*')) {
      throw const DescriptorException(
          'Unsupported derivation path in descriptor');
    }
    throw const DescriptorException(
        'Descriptor must end in a wildcard path (…/*)');
  }

  final path = suffix.substring(0, suffix.length - 2);
  if (path.isEmpty) return (null, null);

  if (path.contains('h') || path.contains("'")) {
    throw const DescriptorException(
        'Hardened derivation after the extended key cannot be watched — '
        're-export the descriptor from your wallet');
  }
  if (path.contains('/')) {
    throw const DescriptorException(
        'Unsupported multi-level derivation path in descriptor');
  }

  // Multipath: <0;1>
  if (path.startsWith('<') && path.endsWith('>')) {
    final options = path.substring(1, path.length - 1).split(';');
    if (options.length != 2) {
      throw const DescriptorException(
          'Multipath descriptors must declare exactly two chains, e.g. <0;1>');
    }
    final receive = int.tryParse(options[0]);
    final change = int.tryParse(options[1]);
    if (receive == null || change == null) {
      throw const DescriptorException('Malformed multipath in descriptor');
    }
    _requireNonHardenedIndex(receive);
    _requireNonHardenedIndex(change);
    return (receive, change);
  }

  final single = int.tryParse(path);
  if (single == null) {
    throw const DescriptorException(
        'Unsupported derivation path in descriptor');
  }
  _requireNonHardenedIndex(single);
  return (single, null);
}

void _requireNonHardenedIndex(int index) {
  if (index < 0 || index >= 0x80000000) {
    throw const DescriptorException(
        'Derivation index out of range in descriptor');
  }
}

// ── Internals: BIP380 checksum ───────────────────────────────────────────────

const _descsumInputCharset =
    "0123456789()[],'/*abcdefgh@:\$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~"
    'ijklmnopqrstuvwxyzABCDEFGH`#"\\ ';

const _descsumChecksumCharset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

const _descsumGenerator = <int>[
  0xf5dee51989,
  0xa9fdca3312,
  0x1bab10e32d,
  0x3706b1677a,
  0x644d626ffd,
];

/// Verifies a trailing `#checksum` if present, and returns the descriptor
/// body without it.
///
/// A descriptor with no checksum is accepted — several wallets export
/// unchecksummed strings — but a *wrong* checksum is always fatal.
String _verifyAndStripChecksum(String input) {
  final hash = input.indexOf('#');
  if (hash < 0) return input;

  final body = input.substring(0, hash);
  final provided = input.substring(hash + 1);

  if (body.contains('#') || provided.contains('#')) {
    throw const DescriptorException('Malformed descriptor checksum');
  }
  if (provided.length != 8) {
    throw const DescriptorException(
        'Descriptor checksum must be 8 characters');
  }

  final expected = _descsumCreate(body);
  if (expected == null) {
    throw const DescriptorException(
        'Descriptor contains characters that are not valid in a descriptor');
  }
  if (expected != provided) {
    throw const DescriptorException(
        'Descriptor checksum does not match — the descriptor was mistyped '
        'or truncated');
  }
  return body;
}

String? _descsumCreate(String body) {
  final symbols = _descsumExpand(body);
  if (symbols == null) return null;
  final checksum = _descsumPolymod([...symbols, 0, 0, 0, 0, 0, 0, 0, 0]) ^ 1;
  final sb = StringBuffer();
  for (var i = 0; i < 8; i++) {
    sb.write(_descsumChecksumCharset[(checksum >> (5 * (7 - i))) & 31]);
  }
  return sb.toString();
}

List<int>? _descsumExpand(String s) {
  final groups = <int>[];
  final symbols = <int>[];
  for (final ch in s.split('')) {
    final v = _descsumInputCharset.indexOf(ch);
    if (v < 0) return null;
    symbols.add(v & 31);
    groups.add(v >> 5);
    if (groups.length == 3) {
      symbols.add(groups[0] * 9 + groups[1] * 3 + groups[2]);
      groups.clear();
    }
  }
  if (groups.length == 1) {
    symbols.add(groups[0]);
  } else if (groups.length == 2) {
    symbols.add(groups[0] * 3 + groups[1]);
  }
  return symbols;
}

int _descsumPolymod(List<int> symbols) {
  var chk = 1;
  for (final value in symbols) {
    final top = chk >> 35;
    chk = ((chk & 0x7ffffffff) << 5) ^ value;
    for (var i = 0; i < 5; i++) {
      if (((top >> i) & 1) == 1) chk ^= _descsumGenerator[i];
    }
  }
  return chk;
}
