import 'package:flutter_test/flutter_test.dart';
import 'package:ig_follow/ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('withinDailyLimit stops at the limit', () {
    expect(withinDailyLimit(0, 30), isTrue);
    expect(withinDailyLimit(29, 30), isTrue);
    expect(withinDailyLimit(30, 30), isFalse);
  });

  test('markDone records accounts and counts only real follows', () async {
    SharedPreferences.setMockInitialValues({});
    final ledger = FollowLedger(await SharedPreferences.getInstance());

    await ledger.markDone('Alpha', countsAsFollow: true);
    await ledger.markDone('beta', countsAsFollow: false);

    expect(ledger.done, {'alpha', 'beta'});
    expect(ledger.todayCount, 1);
  });

  test('reset clears progress', () async {
    SharedPreferences.setMockInitialValues({});
    final ledger = FollowLedger(await SharedPreferences.getInstance());
    await ledger.markDone('alpha', countsAsFollow: true);

    await ledger.reset();

    expect(ledger.done, isEmpty);
    expect(ledger.todayCount, 0);
  });
}
