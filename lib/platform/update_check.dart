/// Checks for new releases on GitHub and notifies the user (#247).
///
/// One [UpdateChecker] for the whole app: it reads its settings (check
/// on/off, pre-releases, last check time) from [ViewSettings], so the
/// once-a-day limit survives a restart. While a check runs, every call
/// gets the same Future; each HTTP request times out after 15 seconds.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../settings/view_settings.dart';
import 'desktop.dart';

/// The GitHub API URL for the latest full release (never a pre-release
/// or draft).
final latestReleaseUrl = Uri.parse(
    'https://api.github.com/repos/ChristianGeng/roam-graph-mobile/releases/latest');

/// The GitHub API URL for all releases (to find pre-releases).
final allReleasesUrl = Uri.parse(
    'https://api.github.com/repos/ChristianGeng/roam-graph-mobile/releases');

/// How long to wait between update checks (24 hours).
const checkInterval = Duration(hours: 24);

/// How long one HTTP request may take.
const requestTimeout = Duration(seconds: 15);

/// Information about a GitHub release.
class GitHubRelease {
  const GitHubRelease({
    required this.tagName,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.publishedAt,
    required this.isPrerelease,
    required this.isDraft,
  });

  final String tagName;
  final String name;
  final String body;
  final String htmlUrl;
  final DateTime publishedAt;
  final bool isPrerelease;
  final bool isDraft;

  /// True if this is a full release (not a pre-release or draft).
  bool get isFullRelease => !isPrerelease && !isDraft;

  /// Parses a release from JSON; missing fields become empty values.
  factory GitHubRelease.fromJson(Map<String, dynamic> json) {
    return GitHubRelease(
      tagName: json['tag_name'] as String? ?? '',
      name: json['name'] as String? ?? '',
      body: json['body'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? '',
      publishedAt:
          DateTime.tryParse(json['published_at'] as String? ?? '') ??
              DateTime(1970),
      isPrerelease: json['prerelease'] as bool? ?? false,
      isDraft: json['draft'] as bool? ?? false,
    );
  }

  /// The version string without the 'v' prefix, for comparison.
  String get version =>
      tagName.startsWith('v') ? tagName.substring(1) : tagName;
}

/// Result of an update check.
class UpdateCheckResult {
  const UpdateCheckResult({
    this.available = false,
    this.release,
    this.error,
    this.lastCheckTime,
  });

  final bool available;
  final GitHubRelease? release;
  final String? error;
  final DateTime? lastCheckTime;
}

/// Compares two version strings semantically.
///
/// Returns positive if [a] > [b], negative if [a] < [b], zero if equal.
/// Handles "0.2.4", "0.2.4-dev.590", "v0.2.4"; pre-release numbers compare
/// numerically, so "dev.9" < "dev.10".
int compareVersions(String a, String b) {
  a = a.startsWith('v') ? a.substring(1) : a;
  b = b.startsWith('v') ? b.substring(1) : b;

  final aParts = a.split('-');
  final bParts = b.split('-');

  final aMain = aParts.firstOrNull ?? '';
  final bMain = bParts.firstOrNull ?? '';
  final aMainParts =
      aMain.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final bMainParts =
      bMain.split('.').map((s) => int.tryParse(s) ?? 0).toList();

  final mainLength = aMainParts.length < bMainParts.length
      ? aMainParts.length
      : bMainParts.length;
  for (var i = 0; i < mainLength; i++) {
    final cmp = aMainParts[i].compareTo(bMainParts[i]);
    if (cmp != 0) return cmp;
  }
  if (aMainParts.length != bMainParts.length) {
    return aMainParts.length.compareTo(bMainParts.length);
  }

  // A pre-release is older than the release itself.
  if (aParts.length > 1 && bParts.length == 1) return -1;
  if (aParts.length == 1 && bParts.length > 1) return 1;
  if (aParts.length == 1) return 0;

  final aPreParts = aParts[1].split('.');
  final bPreParts = bParts[1].split('.');
  final preLength = aPreParts.length < bPreParts.length
      ? aPreParts.length
      : bPreParts.length;
  for (var i = 0; i < preLength; i++) {
    final aNum = int.tryParse(aPreParts[i]);
    final bNum = int.tryParse(bPreParts[i]);
    if (aNum != null && bNum != null) {
      final cmp = aNum.compareTo(bNum);
      if (cmp != 0) return cmp;
    } else if (aNum != null) {
      return -1; // numbers sort before strings
    } else if (bNum != null) {
      return 1;
    } else {
      final cmp = aPreParts[i].compareTo(bPreParts[i]);
      if (cmp != 0) return cmp;
    }
  }
  return aPreParts.length.compareTo(bPreParts.length);
}

/// True if [a] is newer than [b].
bool isNewerVersion(String a, String b) => compareVersions(a, b) > 0;

/// Where the update settings come from: "Check for updates", "Include
/// pre-releases" and the last check time, saved with the other settings.
abstract interface class UpdateSettings {
  bool get checkForUpdates;
  bool get includePreReleases;
  DateTime? get lastCheckTime;
  Future<void> saveLastCheckTime(DateTime time);
}

/// [UpdateSettings] in memory, for tests.
class MemoryUpdateSettings implements UpdateSettings {
  MemoryUpdateSettings({
    this.checkForUpdates = true,
    this.includePreReleases = false,
    this.lastCheckTime,
  });

  @override
  bool checkForUpdates;

  @override
  bool includePreReleases;

  @override
  DateTime? lastCheckTime;

  @override
  Future<void> saveLastCheckTime(DateTime time) async {
    lastCheckTime = time;
  }
}

/// [UpdateSettings] backed by [ViewSettings]: the settings stay current
/// because they are read from the notifier, and the last check time is
/// saved with them, so it survives a restart.
class ViewSettingsUpdateSettings implements UpdateSettings {
  ViewSettingsUpdateSettings({
    required this.notifier,
    required this.onSave,
  });

  /// The app's settings; read on every access, so a change applies at once.
  final ValueNotifier<ViewSettings> notifier;

  /// Saves changed settings.
  final Future<void> Function(ViewSettings) onSave;

  ViewSettings get _settings => notifier.value;

  @override
  bool get checkForUpdates => _settings.checkForUpdates;

  @override
  bool get includePreReleases => _settings.includePreReleases;

  @override
  DateTime? get lastCheckTime => _settings.lastUpdateCheckTime;

  @override
  Future<void> saveLastCheckTime(DateTime time) =>
      onSave(_settings.copyWith(lastUpdateCheckTime: time));
}

/// Fetches releases from GitHub.
abstract interface class ReleaseFetcher {
  /// The latest full release, or null on any failure.
  Future<GitHubRelease?> fetchLatestRelease();

  /// All non-draft releases, or an empty list on any failure.
  Future<List<GitHubRelease>> fetchAllReleases();
}

/// [ReleaseFetcher] using the GitHub API; every request times out after
/// [requestTimeout].
class GitHubReleaseFetcher implements ReleaseFetcher {
  GitHubReleaseFetcher({http.Client? client, Duration? timeout})
      : client = client ?? http.Client(),
        timeout = timeout ?? requestTimeout;

  final http.Client client;

  /// How long one request may take; [requestTimeout] in the app, shorter
  /// in tests.
  final Duration timeout;

  @override
  Future<GitHubRelease?> fetchLatestRelease() async {
    try {
      final response =
          await client.get(latestReleaseUrl).timeout(timeout);
      if (response.statusCode == 200) {
        return GitHubRelease.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>);
      }
      return null; // 403/429 rate limit, 404, …
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<GitHubRelease>> fetchAllReleases() async {
    try {
      final response =
          await client.get(allReleasesUrl).timeout(timeout);
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        return list
            .map((item) =>
                GitHubRelease.fromJson(item as Map<String, dynamic>))
            .where((release) => !release.isDraft)
            .toList();
      }
      return [];
    } on TimeoutException {
      return [];
    } catch (_) {
      return [];
    }
  }
}

/// The one update checker of the app: settings from [UpdateSettings], one
/// check at a time (a second call while one runs gets the same Future).
class UpdateChecker {
  UpdateChecker({
    required this.currentVersion,
    required this.settings,
    ReleaseFetcher? fetcher,
    Future<bool> Function()? isOnline,
    DateTime Function()? now,
    Duration? onlineTimeout,
  })  : fetcher = fetcher ?? GitHubReleaseFetcher(),
        _isOnline = isOnline ?? _lookupOnline,
        _now = now ?? DateTime.now,
        onlineTimeout = onlineTimeout ?? requestTimeout;

  final String currentVersion;
  final UpdateSettings settings;
  final ReleaseFetcher fetcher;

  /// Tests replace the connectivity check.
  final Future<bool> Function() _isOnline;

  /// Tests replace the clock.
  final DateTime Function() _now;

  /// How long the connectivity check may take; a check that takes longer
  /// counts as offline (#268). [requestTimeout] in the app, shorter in
  /// tests.
  final Duration onlineTimeout;

  /// The check currently running; a second call gets the same Future.
  Future<UpdateCheckResult>? _inFlight;

  /// The result of the last finished check.
  UpdateCheckResult? _lastResult;

  /// The result of the last finished check, if any.
  UpdateCheckResult? get lastResult => _lastResult;

  /// Whether an update is available per the last check.
  bool get isUpdateAvailable => _lastResult?.available ?? false;

  /// Whether to check now: the setting is on and the last check (saved
  /// with the settings) is over [checkInterval] ago or never happened.
  bool get shouldCheck =>
      settings.checkForUpdates &&
      (settings.lastCheckTime == null ||
          _now().difference(settings.lastCheckTime!) >= checkInterval);

  /// Checks for updates. While a check runs, every call — forced or not —
  /// gets the same Future. Without [force], a check within [checkInterval]
  /// returns the last result without a request.
  Future<UpdateCheckResult> checkForUpdates({bool force = false}) {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    if (!force && !shouldCheck) {
      return Future.value(_lastResult ?? const UpdateCheckResult());
    }
    final future = _performCheck().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<UpdateCheckResult> _performCheck() async {
    final checkedAt = _now();
    try {
      // A stalled resolver must not hang the check: after [onlineTimeout]
      // it counts as offline (#268).
      final online = kIsWeb ? true : await _onlineWithinTimeout();
      if (online == null) {
        // Cancelled by dispose(): not a check, so nothing is saved and the
        // last result stays.
        return const UpdateCheckResult(available: false, error: 'Cancelled');
      }
      if (!online) {
        return await _finish(
            const UpdateCheckResult(available: false, error: 'Offline'),
            checkedAt);
      }
      final release = settings.includePreReleases
          ? _newest(await fetcher.fetchAllReleases())
          : await fetcher.fetchLatestRelease();
      if (release == null) {
        return await _finish(
            const UpdateCheckResult(
                available: false, error: 'Could not fetch release information'),
            checkedAt);
      }
      if (isNewerVersion(release.version, currentVersion)) {
        return await _finish(
            UpdateCheckResult(
                available: true, release: release, lastCheckTime: checkedAt),
            checkedAt);
      }
      return await _finish(
          UpdateCheckResult(available: false, lastCheckTime: checkedAt),
          checkedAt);
    } catch (e) {
      return await _finish(
          UpdateCheckResult(
              available: false, error: e.toString(), lastCheckTime: checkedAt),
          checkedAt);
    }
  }

  Future<UpdateCheckResult> _finish(
      UpdateCheckResult result, DateTime checkedAt) async {
    _lastResult = result;
    // A failed save must not lose the result: the found update is still
    // shown, and the next start simply checks again (#268).
    try {
      await settings.saveLastCheckTime(checkedAt);
    } catch (e) {
      debugPrint('Could not save the update check time: $e');
    }
    return result;
  }

  /// The connectivity checks still waiting for their lookup, each with its
  /// own timer; [dispose] settles them.
  final _pendingLookups = <_PendingLookup>{};

  /// Whether [dispose] was called; later checks end at once, cancelled.
  bool _disposed = false;

  /// [_isOnline], but false once [onlineTimeout] has passed or when the
  /// lookup fails, also synchronously (#268); null when [dispose] cancelled
  /// it. Each lookup has its own timer (not `Future.timeout`, which [dispose]
  /// could not cancel), and the first outcome wins: a lookup that answers
  /// after its time-out changes nothing, also not a later lookup's timer.
  Future<bool?> _onlineWithinTimeout() {
    if (_disposed) return Future.value(null);
    final lookup = _PendingLookup();
    _pendingLookups.add(lookup);
    lookup.timer = Timer(onlineTimeout, () => _settle(lookup, false));
    Future.sync(_isOnline).then(
      (online) => _settle(lookup, online),
      onError: (Object _) => _settle(lookup, false),
    );
    return lookup.result.future;
  }

  void _settle(_PendingLookup lookup, bool? online) {
    if (lookup.result.isCompleted) return;
    lookup.timer?.cancel();
    _pendingLookups.remove(lookup);
    lookup.result.complete(online);
  }

  /// Ends the checker: cancels the timers of waiting connectivity checks
  /// and lets those checks end at once as cancelled, without saving a
  /// check time or changing the last result. Called when the app closes
  /// or replaces the checker.
  void dispose() {
    _disposed = true;
    for (final lookup in _pendingLookups.toList()) {
      _settle(lookup, null);
    }
  }

  static Future<bool> _lookupOnline() async {
    try {
      return (await InternetAddress.lookup('github.com')).isNotEmpty;
    } on SocketException {
      return false;
    }
  }

  static GitHubRelease? _newest(List<GitHubRelease> releases) {
    GitHubRelease? newest;
    for (final release in releases) {
      if (newest == null ||
          isNewerVersion(release.version, newest.version)) {
        newest = release;
      }
    }
    return newest;
  }

  /// The `install.sh` next to [executable] (by default the running app),
  /// if there is one.
  static String installShPath([String? executable]) {
    final exe = executable ?? Platform.resolvedExecutable;
    return path.join(path.dirname(exe), 'install.sh');
  }

  /// True when the app runs from an `install.sh` install: an
  /// `install.sh` sits next to the executable.
  static Future<bool> isInstalledViaInstallSh({String? executable}) async {
    if (!isDesktop) return false;
    try {
      return await File(installShPath(executable)).exists();
    } catch (_) {
      return false;
    }
  }

  /// Runs `install.sh --update` next to [executable] (by default the
  /// running app).
  static Future<ProcessResult> runInstallShUpdate(
      {String? executable}) async {
    return Process.run(installShPath(executable), ['--update']);
  }

  /// "Update and restart" on Linux: runs `install.sh --update`, and on
  /// success starts the new app and quits this one. Throws with the
  /// installer's output on failure; the running app keeps running then.
  static Future<void> updateAndRestart({String? executable}) async {
    final result = await runInstallShUpdate(executable: executable);
    if (result.exitCode != 0) {
      throw ProcessException(
        installShPath(executable),
        const ['--update'],
        result.stderr.toString(),
        result.exitCode,
      );
    }
    final exe = executable ?? Platform.resolvedExecutable;
    await startDetached(exe, const []);
    exit(0);
  }
}

/// One connectivity check waiting for its lookup: its result and timer.
class _PendingLookup {
  final result = Completer<bool?>();
  Timer? timer;
}
