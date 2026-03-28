import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// Verifies Ed25519 license tokens issued by the Bag payment backend.
///
/// Token format (base64url, 96 chars):
///   bytes  0–7  : licenseId (8 random bytes, server-generated per purchase)
///   bytes  8–71 : Ed25519 signature over UTF-8("bag-pro-v1:" + hex(licenseId))
///
/// The 32-byte public key is embedded at compile time. The matching private key
/// lives only in the Cloudflare Worker environment secret — never in this repo.
///
/// To generate a keypair (one-time, store private key in CF):
///   openssl genpkey -algorithm ed25519 -out private.pem
///   openssl pkey -in public.pem -pubin -text -noout
///   # → copy the 32 raw bytes into _publicKeyBytes below
class LicenseKeyService {
  LicenseKeyService._();

  // ── Embedded public key ───────────────────────────────────────────────────
  // 32-byte Ed25519 public key matching the private key in the Cloudflare
  // Worker environment secret ED25519_PRIVATE_KEY. To rotate: run
  // `npx tsx scripts/gen-keypair.ts` in the backend repo, update both the
  // CF secret and these bytes.
  static final Uint8List _publicKeyBytes = Uint8List.fromList(const [
    58, 240, 18, 86, 127, 168, 153, 237, 26, 203, 235, 179, 3, 7, 147, 214,
    233, 146, 94, 172, 95, 219, 115, 34, 101, 160, 167, 110, 223, 223, 16, 81,
  ]);

  // ── Public API ────────────────────────────────────────────────────────────

  /// Verifies a base64url license token.
  ///
  /// Returns `true` if the Ed25519 signature is valid, `false` for any other
  /// result (invalid encoding, wrong length, bad signature).
  static bool verify(String token) {
    try {
      // Strip whitespace so users can paste space-formatted display keys.
      final cleaned = token.replaceAll(RegExp(r'\s+'), '');

      // Pad base64url to a multiple of 4 if needed.
      final padded = _padBase64(cleaned);
      final bytes = base64Url.decode(padded);

      // Expect exactly 72 bytes: 8 (licenseId) + 64 (signature).
      if (bytes.length != 72) return false;

      final licenseId = bytes.sublist(0, 8);
      final signature = bytes.sublist(8, 72);

      final message = utf8.encode('bag-pro-v1:${_hexEncode(licenseId)}');

      final publicKey = ed.PublicKey(_publicKeyBytes);
      return ed.verify(publicKey, Uint8List.fromList(message), signature);
    } catch (_) {
      return false;
    }
  }

  /// Returns the token in a space-separated display format (6-char groups).
  ///
  /// Example: "dGhpcyB pcyBh IHRl c3Qu..."
  /// Spaces are stripped automatically by [verify] before processing.
  static String formatForDisplay(String token) {
    final cleaned = token.replaceAll(RegExp(r'\s+'), '');
    final buffer = StringBuffer();
    for (var i = 0; i < cleaned.length; i += 6) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(cleaned.substring(
          i, i + 6 > cleaned.length ? cleaned.length : i + 6));
    }
    return buffer.toString();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _padBase64(String s) {
    final rem = s.length % 4;
    if (rem == 0) return s;
    return s + '=' * (4 - rem);
  }

  static String _hexEncode(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
