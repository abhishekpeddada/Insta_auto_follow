import 'dart:convert';
import 'dart:io';

/// Returns true while another follow is allowed today.
bool withinDailyLimit(int countToday, int limit) => countToday < limit;

/// Persists which accounts are done and how many follows happened today,
/// so the app survives restarts and does not exceed the daily cap.
///
/// Stored as a small JSON file rather than shared_preferences, which failed
/// with a NoSuchMethodError on the Android build.
class FollowLedger {
  FollowLedger._(this._file, this._state);

  /// Loads the ledger from [file], or starts an empty one if it doesn't exist.
  static Future<FollowLedger> open(File file) async {
    Map<String, dynamic> state = {};
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) state = decoded;
    }
    return FollowLedger._(file, state);
  }

  final File _file;
  final Map<String, dynamic> _state;

  static const _doneKey = 'done_usernames';
  static const _dayKey = 'follow_day';
  static const _dayCountKey = 'follow_day_count';

  Set<String> get done {
    final list = _state[_doneKey];
    return list is List ? list.map((e) => e.toString()).toSet() : <String>{};
  }

  int get todayCount {
    final sameDay = _state[_dayKey] == _todayKey();
    final count = _state[_dayCountKey];
    return sameDay && count is int ? count : 0;
  }

  /// Marks an account as finished. [countsAsFollow] is false when you were
  /// already following it, so it does not use up today's quota.
  Future<void> markDone(String username, {required bool countsAsFollow}) async {
    final updated = done..add(username.toLowerCase());
    _state[_doneKey] = updated.toList();

    if (countsAsFollow) {
      final count = todayCount + 1;
      _state[_dayKey] = _todayKey();
      _state[_dayCountKey] = count;
    }
    await _save();
  }

  Future<void> reset() async {
    _state
      ..remove(_doneKey)
      ..remove(_dayKey)
      ..remove(_dayCountKey);
    await _save();
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(_state), flush: true);
  }

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }
}
