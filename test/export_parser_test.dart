import 'package:flutter_test/flutter_test.dart';
import 'package:ig_follow/export_parser.dart';

void main() {
  const sample = '''
{
  "relationships_following": [
    {
      "title": "",
      "media_list_data": [],
      "string_list_data": [
        {"href": "https://www.instagram.com/alpha", "value": "alpha", "timestamp": 1700000000},
        {"href": "https://www.instagram.com/Beta", "value": "Beta", "timestamp": 1700000100}
      ]
    },
    {
      "string_list_data": [
        {"href": "https://www.instagram.com/alpha", "value": "ALPHA", "timestamp": 1700000200},
        {"href": "https://www.instagram.com/gamma", "value": "gamma"}
      ]
    }
  ]
}
''';

  test('reads every account and removes case-insensitive duplicates', () {
    final targets = parseFollowingJson(sample);

    expect(targets.map((t) => t.username), ['alpha', 'Beta', 'gamma']);
  });

  test('keeps the timestamp when present and null when missing', () {
    final targets = parseFollowingJson(sample);

    expect(targets[0].timestamp, 1700000000);
    expect(targets[2].timestamp, isNull);
  });

  test('accepts a bare list of sections', () {
    const bare = '[{"string_list_data": [{"value": "solo"}]}]';

    expect(parseFollowingJson(bare).single.username, 'solo');
  });

  test('rejects JSON that is not an Instagram export', () {
    expect(
      () => parseFollowingJson('{"something": 1}'),
      throwsA(isA<FormatException>()),
    );
  });
}
