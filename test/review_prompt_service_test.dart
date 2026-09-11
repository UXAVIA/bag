import 'package:bag/services/review_prompt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 9, 10, 9);
    ReviewPromptService.clock = () => now;
    ReviewPromptService.homeAskDelay = Duration.zero;
  });

  Future<bool> asked() async =>
      (await SharedPreferences.getInstance())
          .getBool(ReviewPromptService.keyAsked) ??
      false;

  Future<List<String>> days() async =>
      (await SharedPreferences.getInstance())
          .getStringList(ReviewPromptService.keyHomeDays) ??
      const [];

  test('home screen without holdings records nothing and never asks', () async {
    for (var i = 0; i < 5; i++) {
      await ReviewPromptService.onHomeShown(hasHoldings: false);
      now = now.add(const Duration(days: 1));
    }
    expect(await days(), isEmpty);
    expect(await asked(), isFalse);
  });

  test('asks on the third distinct day with holdings, not before', () async {
    await ReviewPromptService.onHomeShown(hasHoldings: true);
    await ReviewPromptService.onHomeShown(hasHoldings: true); // same day
    expect(await days(), hasLength(1));
    expect(await asked(), isFalse);

    now = now.add(const Duration(days: 1));
    await ReviewPromptService.onHomeShown(hasHoldings: true);
    expect(await asked(), isFalse);

    now = now.add(const Duration(days: 3)); // gaps are fine — distinct days count
    await ReviewPromptService.onHomeShown(hasHoldings: true);
    expect(await days(), hasLength(3));
    expect(await asked(), isTrue);
  });

  test('wallet scan never asks on the first day of use', () async {
    await ReviewPromptService.onHomeShown(hasHoldings: true);
    await ReviewPromptService.afterSuccessfulWalletScan();
    expect(await asked(), isFalse);

    // No home-screen history at all (scan straight after onboarding).
    SharedPreferences.setMockInitialValues({});
    await ReviewPromptService.afterSuccessfulWalletScan();
    expect(await asked(), isFalse);
  });

  test('wallet scan asks once there is an earlier day on record', () async {
    await ReviewPromptService.onHomeShown(hasHoldings: true);
    now = now.add(const Duration(days: 1));
    await ReviewPromptService.afterSuccessfulWalletScan();
    expect(await asked(), isTrue);
  });

  test('the asked flag is terminal — no second ask from either trigger',
      () async {
    SharedPreferences.setMockInitialValues({
      ReviewPromptService.keyAsked: true,
      ReviewPromptService.keyHomeDays: <String>['2026-09-01'],
    });
    await ReviewPromptService.afterSuccessfulWalletScan();
    for (var i = 0; i < 4; i++) {
      await ReviewPromptService.onHomeShown(hasHoldings: true);
      now = now.add(const Duration(days: 1));
    }
    // Day list is not even extended once asked — nothing left to decide.
    expect(await days(), ['2026-09-01']);
    expect(await asked(), isTrue);
  });
}
