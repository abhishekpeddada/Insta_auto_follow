import 'package:shared_preferences/shared_preferences.dart';

/// Returns true while another follow is allowed today.
bool withinDailyLimit(int countToday, int limit) => countToday < limit;

/// Persists which accounts are done and how many follows happened today,
/// so the app survives restarts and does not exceed the daily cap.
class FollowLedger {
  FollowLedger(this._prefs);

  final SharedPreferences _prefs;

  static const _doneKey = 'done_usernames';
  static const _dayKey = 'follow_day';
  static const _dayCountKey = 'follow_day_count';

  Set<String> get done => (_prefs.getStringList(_doneKey) ?? const []).toSet();

  int get todayCount {
    final sameDay = _prefs.getString(_dayKey) == _todayKey();
    return sameDay ? (_prefs.getInt(_dayCountKey) ?? 0) : 0;
  }

  /// Marks an account as finished. [countsAsFollow] is false when you were
  /// already following it, so it does not use up today's quota.
  Future<void> markDone(String username, {required bool countsAsFollow}) async {
    final updated = done..add(username.toLowerCase());
    await _prefs.setStringList(_doneKey, updated.toList());

    if (countsAsFollow) {
      final today = _todayKey();
      final count = todayCount + 1;
      await _prefs.setString(_dayKey, today);
      await _prefs.setInt(_dayCountKey, count);
    }
  }

  Future<void> reset() async {
    await _prefs.remove(_doneKey);
    await _prefs.remove(_dayKey);
    await _prefs.remove(_dayCountKey);
  }

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }
}
