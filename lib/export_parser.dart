import 'dart:convert';

/// One account from the "following" list of an Instagram data export.
class FollowTarget {
  const FollowTarget(this.username, this.timestamp);

  final String username;

  /// Unix time (seconds) when the export says you followed this account.
  final int? timestamp;
}

/// Parses `following.json` from Instagram's "Download your information" export.
///
/// Expected shape:
/// ```json
/// {"relationships_following": [
///   {"string_list_data": [{"href": "...", "value": "username", "timestamp": 1700000000}]}
/// ]}
/// ```
/// A bare top-level list of the same sections is accepted too.
List<FollowTarget> parseFollowingJson(String source) {
  final decoded = jsonDecode(source);

  final List<dynamic> sections;
  if (decoded is Map && decoded['relationships_following'] is List) {
    sections = decoded['relationships_following'] as List<dynamic>;
  } else if (decoded is List) {
    sections = decoded;
  } else {
    throw const FormatException('Not an Instagram following export.');
  }

  final seen = <String>{};
  final targets = <FollowTarget>[];
  for (final section in sections) {
    if (section is! Map) continue;
    final items = section['string_list_data'];
    if (items is! List) continue;

    for (final item in items) {
      if (item is! Map) continue;
      final username = (item['value'] ?? '').toString().trim();
      if (username.isEmpty || !seen.add(username.toLowerCase())) continue;

      final timestamp = item['timestamp'];
      targets.add(FollowTarget(username, timestamp is int ? timestamp : null));
    }
  }
  return targets;
}
