import 'dart:async';

import 'package:bag/core/utils/serial_chain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs bodies one at a time, in call order', () async {
    final chain = SerialChain();
    final log = <String>[];
    final gate = Completer<void>();
    final first = chain.run(() async {
      log.add('first start');
      await gate.future;
      log.add('first end');
    });
    final second = chain.run(() async => log.add('second'));
    await Future<void>.delayed(Duration.zero);
    expect(log, ['first start']);
    gate.complete();
    await Future.wait([first, second]);
    expect(log, ['first start', 'first end', 'second']);
  });

  test('a failing body fails its own call and the next one still runs',
      () async {
    final chain = SerialChain();
    final failed = chain.run(() async => throw StateError('boom'));
    var ran = false;
    final next = chain.run(() async => ran = true);
    await expectLater(failed, throwsStateError);
    await next;
    expect(ran, isTrue);
  });
}
