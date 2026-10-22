import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
const _dailyLimit = 30;
const _pageLoadTimeout = Duration(seconds: 30);
const _minDelayBetweenFollows = Duration(seconds: 45);
const _maxDelayBetweenFollows = Duration(seconds: 120);

/// Runs in the logged-in Instagram profile page and reports one of:
/// clicked | already | login | not-found
const _followScript = r'''
(function () {
  if (document.querySelector('input[name="username"]')) {
    FollowBridge.postMessage('login');
    return;
  }
  const header = document.querySelector('header');
  const buttons = header ? Array.from(header.querySelectorAll('button')) : [];
  const label = (b) => b.innerText.trim();
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
  FollowBridge.postMessage('not-found');
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

    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() => _ledger = FollowLedger(prefs));
    });
  }

  @override
  void dispose() {
    _running = false;
    super.dispose();
  }

  int get _remaining {
    final done = _ledger?.done ?? const <String>{};
    return _targets
        .where((t) => !done.contains(t.username.toLowerCase()))
        .where((t) => !_skipped.contains(t.username.toLowerCase()))
        .length;
  }

  Future<void> _importExport() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    final bytes = picked?.files.single.bytes;
    if (bytes == null) return;

    try {
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
    if (_targets.isEmpty || _ledger == null) {
      setState(() => _status = 'Import a following.json first.');
      return;
    }
    setState(() {
      _running = true;
      _status = 'Starting. Log in to Instagram in the panel if asked.';
    });
    _runLoop();
  }

  Future<void> _runLoop() async {
    final ledger = _ledger!;

    while (_running) {
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
        _stop('Finished. Every account has been processed.');
        return;
      }
      if (!withinDailyLimit(ledger.todayCount, _dailyLimit)) {
        _stop('Daily limit of $_dailyLimit follows reached. Resume tomorrow.');
        return;
      }

      setState(() => _status = 'Opening @${next!.username}...');
      try {
        await _openProfile(next.username);
        await _sleep(const Duration(seconds: 8), const Duration(seconds: 15));

        final result = await _clickFollow();
        switch (result) {
          case 'clicked':
            await ledger.markDone(next.username, countsAsFollow: true);
            setState(() => _status = 'Followed @${next!.username}.');
          case 'already':
            await ledger.markDone(next.username, countsAsFollow: false);
            setState(
                () => _status = '@${next!.username} was already followed.');
          case 'login':
            _stop('Log in to Instagram in the panel, then press Start.');
            return;
          default:
            _skipped.add(next.username.toLowerCase());
            setState(() => _status = 'Skipped @${next!.username} ($result).');
        }
      } on TimeoutException {
        _skipped.add(next.username.toLowerCase());
        setState(() => _status = 'Timed out on @${next!.username}; skipped.');
      }

      if (!_running) break;
      await _sleep(_minDelayBetweenFollows, _maxDelayBetweenFollows);
    }

    if (mounted) setState(() => _running = false);
  }

  void _stop(String message) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _status = message;
    });
  }

  Future<void> _openProfile(String username) async {
    _pageLoaded = Completer<void>();
    await _web.loadRequest(Uri.parse('https://www.instagram.com/$username/'));
    await _pageLoaded!.future.timeout(_pageLoadTimeout);
  }

  Future<String> _clickFollow() async {
    _scriptResult = Completer<String>();
    await _web.runJavaScript(_followScript);
    return _scriptResult!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => 'no-response',
    );
  }

  /// Waits a random duration between [min] and [max] so the pacing is not
  /// perfectly regular. Returns early when the user pauses.
  Future<void> _sleep(Duration min, Duration max) async {
    final spreadMs = max.inMilliseconds - min.inMilliseconds;
    final ms = min.inMilliseconds + _random.nextInt(spreadMs + 1);
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (_running && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _targets.length;
    final doneCount = total - _remaining;
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
                const SizedBox(height: 4),
                Text(
                    'Done $doneCount / $total  ·  Today $today / $_dailyLimit'),
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
