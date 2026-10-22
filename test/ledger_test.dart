import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ig_follow/ledger.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ledger_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  File ledgerFile() => File('${dir.path}/follow_ledger.json');

  test('withinDailyLimit stops at the limit', () {
    expect(withinDailyLimit(0, 30), isTrue);
    expect(withinDailyLimit(29, 30), isTrue);
    expect(withinDailyLimit(30, 30), isFalse);
  });

  test('markDone records accounts and counts only real follows', () async {
    final ledger = await FollowLedger.open(ledgerFile());

    await ledger.markDone('Alpha', countsAsFollow: true);
    await ledger.markDone('beta', countsAsFollow: false);

    expect(ledger.done, {'alpha', 'beta'});
    expect(ledger.todayCount, 1);
  });

  test('progress survives reopening the file', () async {
    final first = await FollowLedger.open(ledgerFile());
    await first.markDone('alpha', countsAsFollow: true);

    final reopened = await FollowLedger.open(ledgerFile());

    expect(reopened.done, {'alpha'});
    expect(reopened.todayCount, 1);
  });

  test('reset clears progress', () async {
    final ledger = await FollowLedger.open(ledgerFile());
    await ledger.markDone('alpha', countsAsFollow: true);

    await ledger.reset();

    expect(ledger.done, isEmpty);
    expect(ledger.todayCount, 0);
  });
}
