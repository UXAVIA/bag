/// Wallet engine library — all parts share the same library scope so that
/// [ZpubKey._] remains private to this library while being accessible
/// across codec, derivation, and encoding layers.
library;

import 'dart:typed_data';
import 'package:pointycastle/export.dart';

part 'xpub_codec.dart';
part 'bip32_derive.dart';
part 'address_encoder.dart';
