/// Tests for update checking (#247): version comparison, release JSON
/// parsing, the fetcher's error cases, one checker for the app with its
/// settings, one check at a time, the once-a-day limit across restarts,
/// and the install.sh availability for "Update and restart".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:roam_graph_mobile/platform/update_check.dart';
import 'package:roam_graph_mobile/settings/about_screen.dart';

/// A fetcher with scripted results, counting the calls.
class FakeFetcher implements ReleaseFetcher {
  FakeFetcher({this.latest, this.all = const []});

  GitHubRelease? latest;
  List<GitHubRelease> all;
  int latestCalls = 0;
  int allCalls = 0;

  /// When set, calls complete only when [complete] is called.
  Completer<GitHubRelease?>? pending;

  @override
  Future<GitHubRelease?> fetchLatestRelease() async {
    latestCalls++;
    final p = pending;
    if (p != null) return p.future;
    return latest;
  }

  @override
  Future<List<GitHubRelease>> fetchAllReleases() async {
    allCalls++;
    return all;
  }
}

GitHubRelease release(String tag,
        {bool prerelease = false, bool draft = false}) =>
    GitHubRelease(
      tagName: tag,
      name: 'Release $tag',
      body: 'Notes of $tag',
      htmlUrl: 'https://example.com/$tag',
      publishedAt: DateTime(2026, 1, 1),
      isPrerelease: prerelease,
      isDraft: draft,
    );

/// A bundle without the changelog, so the About page shows its error row
/// and settles.
class FakeBundle extends AssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      throw StateError('No asset "$key".');
}

/// An http client returning [response] for every request, or never
/// answering when [hangs] is true.
class FakeClient extends http.BaseClient {
  FakeClient(this.response, {this.hangs = false});

  final http.Response response;
  final bool hangs;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    if (hangs) return Completer<http.StreamedResponse>().future;
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

UpdateChecker checkerWith(
  FakeFetcher fetcher,
  MemoryUpdateSettings settings, {
  String currentVersion = '0.2.4',
  bool online = true,
  DateTime? now,
}) =>
    UpdateChecker(
      currentVersion: currentVersion,
      settings: settings,
      fetcher: fetcher,
      isOnline: () async => online,
      now: now != null ? () => now : DateTime.now,
    );

void main() {
  group('compareVersions (#247)', () {
    test('0.2.4 > 0.2.4-dev.590 > 0.2.3', () {
      expect(compareVersions('0.2.4', '0.2.4-dev.590'), 1);
      expect(compareVersions('0.2.4-dev.590', '0.2.3'), 1);
      expect(compareVersions('0.2.4', '0.2.3'), 1);
    });

    test('a -dev.N build counts as older than its release', () {
      expect(isNewerVersion('0.2.4', '0.2.4-dev.590'), isTrue);
      expect(isNewerVersion('0.2.4-dev.590', '0.2.4'), isFalse);
    });

    test('pre-release numbers compare numerically: dev.9 < dev.10', () {
      expect(compareVersions('0.2.4-dev.9', '0.2.4-dev.10'), -1);
      expect(compareVersions('0.2.4-dev.10', '0.2.4-dev.9'), 1);
      expect(compareVersions('0.2.4-dev.99', '0.2.4-dev.100'), -1);
    });

    test('equal versions, with or without v', () {
      expect(compareVersions('1.0.0', '1.0.0'), 0);
      expect(compareVersions('v1.0.0', '1.0.0'), 0);
      expect(compareVersions('v0.2.4-dev.590', '0.2.4-dev.590'), 0);
    });

    test('main version parts compare numerically, not as text', () {
      expect(compareVersions('0.10.0', '0.9.0'), 1);
      expect(compareVersions('0.2.10', '0.2.9'), 1);
    });

    test('pre-release: numbers sort before strings', () {
      expect(compareVersions('1.0.0-dev.1', '1.0.0-dev.alpha'), -1);
      expect(compareVersions('1.0.0-alpha', '1.0.0-beta'), -1);
    });
  });

  group('GitHubRelease.fromJson (#247)', () {
    test('a full release', () {
      final r = GitHubRelease.fromJson({
        'tag_name': 'v0.2.5',
        'name': '0.2.5',
        'body': 'Added x.',
        'html_url': 'https://example.com/v0.2.5',
        'published_at': '2026-02-01T10:00:00Z',
        'prerelease': false,
        'draft': false,
      });
      expect(r.tagName, 'v0.2.5');
      expect(r.version, '0.2.5');
      expect(r.name, '0.2.5');
      expect(r.body, 'Added x.');
      expect(r.htmlUrl, 'https://example.com/v0.2.5');
      expect(r.publishedAt, DateTime.parse('2026-02-01T10:00:00Z'));
      expect(r.isFullRelease, isTrue);
    });

    test('a pre-release', () {
      final r = GitHubRelease.fromJson({
        'tag_name': 'v0.2.5-dev.581',
        'prerelease': true,
        'draft': false,
      });
      expect(r.isPrerelease, isTrue);
      expect(r.isFullRelease, isFalse);
      expect(r.version, '0.2.5-dev.581');
    });

    test('a release with no assets still parses', () {
      final r = GitHubRelease.fromJson({
        'tag_name': 'v1.0.0',
        'assets': <dynamic>[],
      });
      expect(r.version, '1.0.0');
      expect(r.body, '');
      expect(r.htmlUrl, '');
    });

    test('missing fields become empty values', () {
      final r = GitHubRelease.fromJson(<String, dynamic>{});
      expect(r.tagName, '');
      expect(r.version, '');
      expect(r.isFullRelease, isTrue);
    });
  });

  group('GitHubReleaseFetcher error cases (#247)', () {
    test('a 200 response parses the release', () async {
      final fetcher = GitHubReleaseFetcher(
        client: FakeClient(http.Response(jsonEncode({
          'tag_name': 'v0.2.5',
          'name': '0.2.5',
          'html_url': 'u',
          'published_at': '2026-02-01T10:00:00Z',
        }), 200)),
      );
      final r = await fetcher.fetchLatestRelease();
      expect(r?.version, '0.2.5');
    });

    test('rate limit 403 and 429 give null, not an error', () async {
      for (final code in [403, 429]) {
        final fetcher = GitHubReleaseFetcher(
            client: FakeClient(http.Response('rate limited', code)));
        expect(await fetcher.fetchLatestRelease(), isNull);
        expect(await fetcher.fetchAllReleases(), isEmpty);
      }
    });

    test('a timeout gives null', () async {
      final fetcher = GitHubReleaseFetcher(
        client: FakeClient(http.Response('', 200), hangs: true),
        timeout: const Duration(milliseconds: 50),
      );
      expect(await fetcher.fetchLatestRelease(), isNull);
      expect(await fetcher.fetchAllReleases(), isEmpty);
    });

    test('a malformed body gives null', () async {
      final fetcher = GitHubReleaseFetcher(
          client: FakeClient(http.Response('not json', 200)));
      expect(await fetcher.fetchLatestRelease(), isNull);
    });

    test('fetchAllReleases drops drafts', () async {
      final fetcher = GitHubReleaseFetcher(
        client: FakeClient(http.Response(jsonEncode([
          {'tag_name': 'v1.0.0', 'draft': false},
          {'tag_name': 'v1.1.0', 'draft': true},
        ]), 200)),
      );
      final releases = await fetcher.fetchAllReleases();
      expect(releases.map((r) => r.version), ['1.0.0']);
    });
  });

  group('UpdateChecker (#247)', () {
    test('a newer release means an update is available', () async {
      final fetcher = FakeFetcher(latest: release('v0.2.5'));
      final checker = checkerWith(fetcher, MemoryUpdateSettings());
      final result = await checker.checkForUpdates();
      expect(result.available, isTrue);
      expect(result.release?.version, '0.2.5');
      expect(checker.isUpdateAvailable, isTrue);
      expect(checker.lastResult?.release?.version, '0.2.5');
    });

    test('no newer release means up to date', () async {
      final fetcher = FakeFetcher(latest: release('v0.2.4'));
      final checker = checkerWith(fetcher, MemoryUpdateSettings());
      final result = await checker.checkForUpdates();
      expect(result.available, isFalse);
      expect(result.error, isNull);
    });

    test('a failed fetch reports an error', () async {
      final fetcher = FakeFetcher(latest: null);
      final checker = checkerWith(fetcher, MemoryUpdateSettings());
      final result = await checker.checkForUpdates();
      expect(result.available, isFalse);
      expect(result.error, isNotNull);
    });

    test('offline: no request, an "Offline" error', () async {
      final fetcher = FakeFetcher(latest: release('v0.2.5'));
      final checker =
          checkerWith(fetcher, MemoryUpdateSettings(), online: false);
      final result = await checker.checkForUpdates();
      expect(result.available, isFalse);
      expect(result.error, 'Offline');
      expect(fetcher.latestCalls, 0);
    });

    test('the setting off means no request', () async {
      final fetcher = FakeFetcher(latest: release('v0.2.5'));
      final settings = MemoryUpdateSettings(checkForUpdates: false);
      final checker = checkerWith(fetcher, settings);
      expect(checker.shouldCheck, isFalse);
      final result = await checker.checkForUpdates();
      expect(result.available, isFalse);
      expect(fetcher.latestCalls, 0);
    });

    test('the once-a-day limit: no second request within 24 h', () async {
      final now = DateTime(2026, 3, 1, 12);
      final fetcher = FakeFetcher(latest: release('v0.2.5'));
      final settings = MemoryUpdateSettings();
      final checker = checkerWith(fetcher, settings, now: now);
      await checker.checkForUpdates();
      expect(fetcher.latestCalls, 1);
      expect(settings.lastCheckTime, now);
      expect(checker.shouldCheck, isFalse);
      // A second call within the interval makes no request.
      final again = await checker.checkForUpdates();
      expect(fetcher.latestCalls, 1);
      expect(again.available, isTrue);
    });

    test('the limit survives a restart: last check time saved with the '
        'settings', () async {
      final now = DateTime(2026, 3, 1, 12);
      final fetcher = FakeFetcher(latest: release('v0.2.5'));
      final settings = MemoryUpdateSettings();
      await checkerWith(fetcher, settings, now: now).checkForUpdates();
      // "Restart": a new checker with the same saved settings.
      final restarted = checkerWith(fetcher, settings, now: now);
      expect(restarted.shouldCheck, isFalse);
      await restarted.checkForUpdates();
      expect(fetcher.latestCalls, 1);
      // 25 h later it checks again.
      final later = checkerWith(fetcher, settings,
          now: now.add(const Duration(hours: 25)));
      expect(later.shouldCheck, isTrue);
      await later.checkForUpdates();
      expect(fetcher.latestCalls, 2);
    });

    test('force checks even within the interval', () async {
      final now = DateTime(2026, 3, 1, 12);
      final fetcher = FakeFetcher(latest: release('v0.2.5'));
      final settings = MemoryUpdateSettings();
      final checker = checkerWith(fetcher, settings, now: now);
      await checker.checkForUpdates();
      await checker.checkForUpdates(force: true);
      expect(fetcher.latestCalls, 2);
    });

    test('one check at a time: a second call gets the same Future',
        () async {
      final fetcher = FakeFetcher(latest: release('v0.2.5'));
      fetcher.pending = Completer<GitHubRelease?>();
      final checker = checkerWith(fetcher, MemoryUpdateSettings());
      final first = checker.checkForUpdates();
      final second = checker.checkForUpdates();
      final forced = checker.checkForUpdates(force: true);
      expect(identical(first, second), isTrue);
      expect(identical(first, forced), isTrue);
      fetcher.pending!.complete(release('v0.2.5'));
      expect((await first).available, isTrue);
      expect(fetcher.latestCalls, 1);
      // After it finished, a new call starts a new check.
      await checker.checkForUpdates(force: true);
      expect(fetcher.latestCalls, 2);
    });

    test('pre-releases off: only the latest full release is read',
        () async {
      final fetcher = FakeFetcher(
        latest: release('v0.2.5'),
        all: [release('v0.2.6-dev.1', prerelease: true)],
      );
      final checker =
          checkerWith(fetcher, MemoryUpdateSettings(includePreReleases: false));
      final result = await checker.checkForUpdates();
      expect(fetcher.latestCalls, 1);
      expect(fetcher.allCalls, 0);
      expect(result.release?.version, '0.2.5');
    });

    test('pre-releases on: the newest of all releases wins', () async {
      final fetcher = FakeFetcher(
        latest: release('v0.2.5'),
        all: [
          release('v0.2.5'),
          release('v0.2.6-dev.10', prerelease: true),
          release('v0.2.6-dev.9', prerelease: true),
        ],
      );
      final checker =
          checkerWith(fetcher, MemoryUpdateSettings(includePreReleases: true));
      final result = await checker.checkForUpdates();
      expect(fetcher.latestCalls, 0);
      expect(fetcher.allCalls, 1);
      expect(result.available, isTrue);
      expect(result.release?.version, '0.2.6-dev.10');
    });
  });

  group('install.sh availability for "Update and restart" (#247)', () {
    late Directory dir;

    setUp(() async {
      // "Update and restart" is a desktop feature; the tests run as
      // Android by default.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      dir = await Directory.systemTemp.createTemp('roam-update-test');
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await dir.delete(recursive: true);
    });

    test('only offered next to an install.sh', () async {
      final exe = '${dir.path}/app';
      await File(exe).create();
      expect(await UpdateChecker.isInstalledViaInstallSh(executable: exe),
          isFalse);
      await File(UpdateChecker.installShPath(exe)).create();
      expect(await UpdateChecker.isInstalledViaInstallSh(executable: exe),
          isTrue);
    });

    test('install.sh --update runs and its output comes back', () async {
      final exe = '${dir.path}/app';
      await File(exe).create();
      final installSh = File(UpdateChecker.installShPath(exe));
      await installSh.writeAsString('#!/bin/sh\necho updated \$@\n');
      await Process.run('chmod', ['+x', installSh.path]);
      final result =
          await UpdateChecker.runInstallShUpdate(executable: exe);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('--update'));
    });

    test('a failing install.sh --update reports the error', () async {
      final exe = '${dir.path}/app';
      await File(exe).create();
      final installSh = File(UpdateChecker.installShPath(exe));
      await installSh
          .writeAsString('#!/bin/sh\necho broken >&2\nexit 3\n');
      await Process.run('chmod', ['+x', installSh.path]);
      final result =
          await UpdateChecker.runInstallShUpdate(executable: exe);
      expect(result.exitCode, 3);
      expect(result.stderr, contains('broken'));
    });
  });

  group('the About page update status (#247)', () {
    Future<void> pumpAbout(WidgetTester tester, UpdateChecker checker) async {
      await tester.pumpWidget(DefaultAssetBundle(
        bundle: FakeBundle(),
        child: MaterialApp(
          home: AboutScreen(version: '0.2.4', checker: checker),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('checks on open when checking is on, and shows the status',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final fetcher = FakeFetcher(latest: release('v0.2.5'));
        final checker = checkerWith(fetcher, MemoryUpdateSettings());
        await pumpAbout(tester, checker);
        expect(fetcher.latestCalls, 1);
        expect(
            find.byKey(const ValueKey('about-check-status')), findsOneWidget);
        expect(find.text('Update available: 0.2.5'), findsOneWidget);
        expect(find.byKey(const ValueKey('about-update-available')),
            findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('shows "Up to date" when there is no newer release',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final fetcher = FakeFetcher(latest: release('v0.2.4'));
        final checker = checkerWith(fetcher, MemoryUpdateSettings());
        await pumpAbout(tester, checker);
        expect(find.text('Up to date'), findsOneWidget);
        expect(
            find.byKey(const ValueKey('about-update-available')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('shows the error when the check fails', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final fetcher = FakeFetcher(latest: null);
        final checker = checkerWith(fetcher, MemoryUpdateSettings());
        await pumpAbout(tester, checker);
        expect(find.textContaining('Check failed:'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('does not check on open when the setting is off',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final fetcher = FakeFetcher(latest: release('v0.2.5'));
        final checker = checkerWith(
            fetcher, MemoryUpdateSettings(checkForUpdates: false));
        await pumpAbout(tester, checker);
        expect(fetcher.latestCalls, 0);
        expect(find.byKey(const ValueKey('about-check-status')), findsNothing);
        // The refresh button still checks on request.
        await tester.tap(find.byKey(const ValueKey('about-check-for-updates')));
        await tester.pumpAndSettle();
        expect(fetcher.latestCalls, 1);
        expect(find.text('Update available: 0.2.5'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
