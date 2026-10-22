import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'export_parser.dart';
import 'ledger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IgFollowApp());
}

class IgFollowApp extends StatelessWidget {
  const IgFollowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IG Follow',
      theme: ThemeData(colorSchemeSeed: Colors.purple, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// Conservative defaults. Going faster raises the chance Instagram
/// restricts the account.
const _dailyLimit = 100;
const _pageLoadTimeout = Duration(seconds: 30);
const _scriptTimeout = Duration(seconds: 15);
const _minDelayBetweenFollows = Duration(seconds: 10);
const _maxDelayBetweenFollows = Duration(seconds: 10);

/// Runs in the logged-in Instagram profile page and reports one of:
/// clicked | already | login | not-found: <button labels seen>
///
/// Instagram's markup changes, so this searches every button-like element
/// rather than only those inside a <header>. The first "Follow" on the page
/// is the profile's own button, which comes before the suggestion cards.
const _followScript = r'''
(function () {
  if (document.querySelector('input[name="username"]')) {
    FollowBridge.postMessage('login');
    return;
  }
  const buttons = Array.from(
    document.querySelectorAll('button, [role="button"]')
  );
  const label = (b) => (b.innerText || b.textContent || '').trim();
  const follow = buttons.find((b) => label(b) === 'Follow');
  if (follow) {
    follow.click();
    FollowBridge.postMessage('clicked');
    return;
  }
  if (buttons.some((b) => ['Following', 'Requested'].includes(label(b)))) {
    FollowBridge.postMessage('already');
    return;
  }
  const seen = buttons.map(label).filter((t) => t).slice(0, 12).join(' | ');
  FollowBridge.postMessage('not-found: ' + seen);
})();
''';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _random = Random();
  late final WebViewController _web;

  FollowLedger? _ledger;
  List<FollowTarget> _targets = const [];
  final Set<String> _skipped = {};
  bool _running = false;
  String _status = 'Import your following.json to begin.';

  /// Live countdown shown under the last result while the loop waits.
  String _wait = '';

  /// Each Start gets a new id. A loop that finds it is no longer the current
  /// id exits, so a stuck loop can never run alongside a newer one.
  int _runId = 0;

  Completer<void>? _pageLoaded;
  Completer<String>? _scriptResult;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FollowBridge',
        onMessageReceived: (message) =>
            _scriptResult?.complete(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _pageLoaded?.complete(),
        ),
      )
      ..loadRequest(Uri.parse('https://www.instagram.com/accounts/login/'));

    _openLedger();
  }

  Future<void> _openLedger() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final ledger =
          await FollowLedger.open(File('${dir.path}/follow_ledger.json'));
      if (!mounted) return;
      setState(() => _ledger = ledger);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Could not load saved progress: $error');
    }
  }

  @override
  void dispose() {
    _running = false;
    super.dispose();
  }

  Future<void> _importExport() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (picked == null) return;

    try {
      final bytes = await picked.readAsBytes();
      final targets = parseFollowingJson(utf8.decode(bytes));
      setState(() {
        _targets = targets;
        _skipped.clear();
        _status = 'Loaded ${targets.length} accounts.';
      });
    } on FormatException catch (e) {
      setState(() => _status = 'Import failed: ${e.message}');
    }
  }

  void _toggleRunning() {
    if (_running) {
      setState(() {
        _running = false;
        _status = 'Pausing after the current account...';
      });
      return;
    }
    if (_targets.isEmpty) {
      setState(() => _status = 'Import a following.json first.');
      return;
    }
    if (_ledger == null) {
      setState(() => _status =
          'Still loading saved progress. Press Start again in a moment.');
      return;
    }
    final runId = ++_runId;
    setState(() {
      _running = true;
      _status = 'Starting. Log in to Instagram in the panel if asked.';
    });
    _runLoop(runId);
  }

  bool _isCurrent(int runId) => _running && runId == _runId;

  Future<void> _runLoop(int runId) async {
    final ledger = _ledger!;

    while (_isCurrent(runId)) {
      final done = ledger.done;
      FollowTarget? next;
      for (final t in _targets) {
        final key = t.username.toLowerCase();
        if (!done.contains(key) && !_skipped.contains(key)) {
          next = t;
          break;
        }
      }

      if (next == null) {
        _stop(runId, 'Finished. Every account has been processed.');
        return;
      }
      if (!withinDailyLimit(ledger.todayCount, _dailyLimit)) {
        _stop(runId,
            'Daily limit of $_dailyLimit follows reached. Resume tomorrow.');
        return;
      }

      final username = next.username;
      setState(() => _status = 'Opening @$username...');
      try {
        await _openProfile(username);
        await _sleep(runId, 'Checking @$username in',
            const Duration(seconds: 8), const Duration(seconds: 15));
        if (!_isCurrent(runId)) return;

        final result = await _clickFollow();
        if (!_isCurrent(runId)) return;

        switch (result) {
          case 'clicked':
            await ledger.markDone(username, countsAsFollow: true);
            setState(() => _status = 'Followed @$username.');
          case 'already':
            await ledger.markDone(username, countsAsFollow: false);
            setState(() => _status = '@$username was already followed.');
          case 'login':
            _stop(runId, 'Log in to Instagram in the panel, then press Start.');
            return;
          default:
            _skipped.add(username.toLowerCase());
            setState(() => _status = 'Skipped @$username ($result).');
        }
      } on TimeoutException {
        _skipped.add(username.toLowerCase());
        if (!_isCurrent(runId)) return;
        setState(() => _status = 'Timed out on @$username; skipped.');
      }

      await _sleep(runId, 'Next account in', _minDelayBetweenFollows,
          _maxDelayBetweenFollows);
    }
  }

  void _stop(int runId, String message) {
    if (!mounted || runId != _runId) return;
    setState(() {
      _running = false;
      _status = message;
    });
  }

  Future<void> _openProfile(String username) async {
    _pageLoaded = Completer<void>();
    await _web
        .loadRequest(Uri.parse('https://www.instagram.com/$username/'))
        .timeout(_pageLoadTimeout);
    await _pageLoaded!.future.timeout(_pageLoadTimeout);
  }

  /// Every step is bounded by a timeout so the loop can never hang here.
  Future<String> _clickFollow() async {
    _scriptResult = Completer<String>();
    try {
      await _web.runJavaScript(_followScript).timeout(_scriptTimeout);
    } on TimeoutException {
      return 'no-response';
    }
    return _scriptResult!.future.timeout(
      _scriptTimeout,
      onTimeout: () => 'no-response',
    );
  }

  /// Waits a random duration between [min] and [max] so the pacing is not
  /// perfectly regular, showing a countdown labelled [prefix]. Returns early
  /// when the user pauses or a new run starts.
  Future<void> _sleep(
      int runId, String prefix, Duration min, Duration max) async {
    final spreadMs = max.inMilliseconds - min.inMilliseconds;
    final ms = min.inMilliseconds + _random.nextInt(spreadMs + 1);
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (_isCurrent(runId)) {
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) break;
      setState(() => _wait = '$prefix ${left.inSeconds + 1}s');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (mounted) setState(() => _wait = '');
  }

  @override
  Widget build(BuildContext context) {
    final total = _targets.length;
    final done = _ledger?.done ?? const <String>{};
    final doneCount =
        _targets.where((t) => done.contains(t.username.toLowerCase())).length;
    final today = _ledger?.todayCount ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('IG Follow')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_status),
                if (_wait.isNotEmpty) Text(_wait),
                const SizedBox(height: 4),
                Text(
                  'Done $doneCount / $total  ·  Skipped ${_skipped.length}'
                  '  ·  Today $today / $_dailyLimit',
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                    value: total == 0 ? 0 : doneCount / total),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _running ? null : _importExport,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Import'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _toggleRunning,
                      icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                      label: Text(_running ? 'Pause' : 'Start'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: WebViewWidget(controller: _web)),
        ],
      ),
    );
  }
}
