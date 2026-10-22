# IG Follow

A Flutter app that reads your Instagram data export (`following.json`) and
follows the same accounts from your current account, one at a time, with
randomized delays and a daily cap. GitHub Actions builds the Android APK.

## Important: read before using

- Automating follows is against Instagram's Terms of Use. Instagram can
  restrict or disable the account that runs it. The defaults here (30 follows
  per day, 45–120 seconds between follows) are deliberately slow. Do not raise
  them.
- The app never asks for or stores your password. You log in inside the
  Instagram panel in the app, and the session stays in the app's WebView.
- Your export contains personal data. The `.gitignore` excludes `*.json`, so
  do not commit it.

## Getting your export

1. Instagram app or web → Accounts Center → **Your information and permissions**
   → **Download your information**.
2. Choose **Some of your information**, then **Connections** →
   **Followers and following**, format **JSON**.
3. Download, then copy `following.json` to your phone.

## How it works

- `lib/export_parser.dart` parses `relationships_following` and drops
  duplicates (case-insensitive).
- `lib/ledger.dart` saves finished accounts and today's follow count with
  `shared_preferences`, so restarts resume where they stopped.
- `lib/main.dart` opens each profile in a WebView, waits for the page, and
  clicks the **Follow** button in the profile header. It skips accounts already
  followed, and stops when it hits a login screen or the daily cap.

Instagram changes its page markup from time to time. If follows stop
registering, update `_followScript` in `lib/main.dart`.

## Build

Pushes to `main` and pull requests run `.github/workflows/flutter.yml`:
`flutter analyze`, `flutter test`, then `flutter build apk --release`.
Download the `ig-follow-apk` artifact from the workflow run and install it on
Android (allow installs from unknown sources).

Local run (needs Flutter installed):

```sh
flutter create --platforms=android --project-name ig_follow --org com.example .
flutter pub get
flutter test
flutter run
```

The platform folders are generated, not committed, which is why the workflow
runs `flutter create` when `android/` is missing.
