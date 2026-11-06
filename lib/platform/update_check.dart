/// Checks for new releases on GitHub and notifies the user (#247).
///
/// On start, at most once a day, the app asks GitHub for the latest full
/// release and compares it with the installed version. If a newer release
/// exists, it shows a notification and offers to update (Linux only).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../settings/view_settings.dart';
import 'package:path/path.dart' as path;

import 'desktop.dart';

/// The GitHub API URL for the latest release.
final _latestReleaseUrl = Uri.parse(
    'https://api.github.com/repos/ChristianGeng/roam-graph-mobile/releases/latest');

/// The GitHub API URL for all releases (to find pre-releases).
final _allReleasesUrl = Uri.parse(
    'https://api.github.com/repos/ChristianGeng/roam-graph-mobile/releases');

/// How long to wait between update checks (24 hours).
const _checkInterval = Duration(hours: 24);

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

  /// Returns true if this is a full release (not a pre-release or draft).
  bool get isFullRelease => !isPrerelease && !isDraft;

  /// Parses a release from JSON.
  factory GitHubRelease.fromJson(Map<String, dynamic> json) {
    return GitHubRelease(
      tagName: json['tag_name'] as String? ?? '',
      name: json['name'] as String? ?? '',
      body: json['body'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? '',
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? '') ?? DateTime(1970),
      isPrerelease: json['prerelease'] as bool? ?? false,
      isDraft: json['draft'] as bool? ?? false,
    );
  }

  /// The version string without the 'v' prefix, for comparison.
  String get version => tagName.startsWith('v') ? tagName.substring(1) : tagName;
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
/// Returns:
/// - positive if [a] > [b]
/// - negative if [a] < [b]
/// - zero if [a] == [b]
///
/// Handles versions like "0.2.4", "0.2.4-dev.590", "v0.2.4".
int compareVersions(String a, String b) {
  // Remove 'v' prefix if present
  a = a.startsWith('v') ? a.substring(1) : a;
  b = b.startsWith('v') ? b.substring(1) : b;

  // Split into parts
  final aParts = a.split('-');
  final bParts = b.split('-');

  // Compare main version parts (e.g., "0.2.4")
  final aMain = aParts.firstOrNull ?? '';
  final bMain = bParts.firstOrNull ?? '';

  final aMainParts = aMain.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final bMainParts = bMain.split('.').map((s) => int.tryParse(s) ?? 0).toList();

  // Compare each part
  for (var i = 0; i < aMainParts.length && i < bMainParts.length; i++) {
    final cmp = aMainParts[i].compareTo(bMainParts[i]);
    if (cmp != 0) return cmp;
  }

  // If main versions are equal, compare pre-release parts
  // A version with a pre-release suffix is older than the same version without
  if (aParts.length > 1 && bParts.length == 1) return -1;
  if (aParts.length == 1 && bParts.length > 1) return 1;
  if (aParts.length > 1 && bParts.length > 1) {
    // Both have pre-release parts, compare them properly
    // Split the pre-release parts and compare each segment
    final aPre = aParts[1];
    final bPre = bParts[1];
    final aPreParts = aPre.split('.');
    final bPreParts = bPre.split('.');
    
    for (var i = 0; i < aPreParts.length && i < bPreParts.length; i++) {
      final aPart = aPreParts[i];
      final bPart = bPreParts[i];
      
      // Try to parse as numbers first
      final aNum = int.tryParse(aPart);
      final bNum = int.tryParse(bPart);
      
      if (aNum != null && bNum != null) {
        // Both are numbers, compare numerically
        final cmp = aNum.compareTo(bNum);
        if (cmp != 0) return cmp;
      } else if (aNum != null) {
        // a is number, b is not - numbers come before strings
        return -1;
      } else if (bNum != null) {
        // b is number, a is not - numbers come before strings
        return 1;
      } else {
        // Both are strings, compare lexicographically
        final cmp = aPart.compareTo(bPart);
        if (cmp != 0) return cmp;
      }
    }
    
    // If all compared parts are equal, the one with more parts is newer
    return aPreParts.length.compareTo(bPreParts.length);
  }

  // If one has more parts, it's newer
  return aMainParts.length.compareTo(bMainParts.length);
}

/// Checks if [a] is newer than [b].
bool isNewerVersion(String a, String b) => compareVersions(a, b) > 0;

/// Stores update check preferences.
abstract interface class UpdatePreferences {
  /// Whether to check for updates.
  bool get checkForUpdates;

  /// Whether to include pre-releases.
  bool get includePreReleases;

  /// The last time an update check was performed.
  DateTime? get lastCheckTime;

  /// The last seen version from an update check.
  String? get lastSeenVersion;

  /// Sets whether to check for updates.
  Future<void> setCheckForUpdates(bool value);

  /// Sets whether to include pre-releases.
  Future<void> setIncludePreReleases(bool value);

  /// Sets the last check time.
  Future<void> setLastCheckTime(DateTime? time);

  /// Sets the last seen version.
  Future<void> setLastSeenVersion(String? version);
}

/// Default implementation of [UpdatePreferences] using a map.
///
/// In the real app, this would be backed by shared preferences or similar.
class MemoryUpdatePreferences implements UpdatePreferences {
  MemoryUpdatePreferences({
    bool checkForUpdates = true,
    bool includePreReleases = false,
    DateTime? lastCheckTime,
    String? lastSeenVersion,
  })  : _checkForUpdates = checkForUpdates,
        _includePreReleases = includePreReleases,
        _lastCheckTime = lastCheckTime,
        _lastSeenVersion = lastSeenVersion;

  bool _checkForUpdates;
  bool _includePreReleases;
  DateTime? _lastCheckTime;
  String? _lastSeenVersion;

  @override
  bool get checkForUpdates => _checkForUpdates;

  @override
  bool get includePreReleases => _includePreReleases;

  @override
  DateTime? get lastCheckTime => _lastCheckTime;

  @override
  String? get lastSeenVersion => _lastSeenVersion;

  @override
  Future<void> setCheckForUpdates(bool value) async {
    _checkForUpdates = value;
  }

  @override
  Future<void> setIncludePreReleases(bool value) async {
    _includePreReleases = value;
  }

  @override
  Future<void> setLastCheckTime(DateTime? time) async {
    _lastCheckTime = time;
  }

  @override
  Future<void> setLastSeenVersion(String? version) async {
    _lastSeenVersion = version;
  }
}

/// Implementation of [UpdatePreferences] that delegates to a callback.
///
/// This allows the update checker to trigger saves to the actual settings store.
class CallbackUpdatePreferences implements UpdatePreferences {
  CallbackUpdatePreferences({
    required this.checkForUpdates,
    required this.includePreReleases,
    required this.lastCheckTime,
    required this.lastSeenVersion,
    required this.onSave,
  });

  @override
  final bool checkForUpdates;

  @override
  final bool includePreReleases;

  @override
  final DateTime? lastCheckTime;

  @override
  final String? lastSeenVersion;

  /// Callback to save preferences.
  final Future<void> Function(bool, bool, DateTime?, String?) onSave;

  @override
  Future<void> setCheckForUpdates(bool value) async {
    await onSave(value, includePreReleases, lastCheckTime, lastSeenVersion);
  }

  @override
  Future<void> setIncludePreReleases(bool value) async {
    await onSave(checkForUpdates, value, lastCheckTime, lastSeenVersion);
  }

  @override
  Future<void> setLastCheckTime(DateTime? time) async {
    await onSave(checkForUpdates, includePreReleases, time, lastSeenVersion);
  }

  @override
  Future<void> setLastSeenVersion(String? version) async {
    await onSave(checkForUpdates, includePreReleases, lastCheckTime, version);
  }
}

/// Creates [UpdatePreferences] from [ViewSettings] with a save callback.
///
/// This bridges the update checker with the app's settings system.
CallbackUpdatePreferences updatePreferencesFromViewSettings({
  required ViewSettings settings,
  required Future<void> Function(ViewSettings) onSave,
}) {
  return CallbackUpdatePreferences(
    checkForUpdates: settings.checkForUpdates,
    includePreReleases: settings.includePreReleases,
    lastCheckTime: settings.lastUpdateCheckTime,
    lastSeenVersion: settings.lastSeenVersion,
    onSave: (checkForUpdates, includePreReleases, lastCheckTime, lastSeenVersion) async {
      await onSave(settings.copyWith(
        checkForUpdates: checkForUpdates,
        includePreReleases: includePreReleases,
        lastUpdateCheckTime: lastCheckTime,
        lastSeenVersion: lastSeenVersion,
      ));
    },
  );
}

/// Fetches releases from GitHub.
abstract interface class ReleaseFetcher {
  /// Fetches the latest full release.
  Future<GitHubRelease?> fetchLatestRelease();

  /// Fetches all releases.
  Future<List<GitHubRelease>> fetchAllReleases();
}

/// Default implementation using the GitHub API.
class GitHubReleaseFetcher implements ReleaseFetcher {
  GitHubReleaseFetcher({http.Client? client})
      : client = client ?? http.Client();

  final http.Client client;

  /// Timeout for HTTP requests (10 seconds).
  static const _timeout = Duration(seconds: 10);

  @override
  Future<GitHubRelease?> fetchLatestRelease() async {
    try {
      final response = await client.get(_latestReleaseUrl).timeout(_timeout);
      if (response.statusCode == 200) {
        return GitHubRelease.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>);
      }
      return null;
    } on TimeoutException {
      // Request timed out
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<GitHubRelease>> fetchAllReleases() async {
    try {
      final response = await client.get(_allReleasesUrl).timeout(_timeout);
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        return list
            .map((item) => GitHubRelease.fromJson(
                  item as Map<String, dynamic>))
            .where((release) => !release.isDraft)
            .toList();
      }
      return [];
    } on TimeoutException {
      // Request timed out
      return [];
    } catch (_) {
      return [];
    }
  }
}

/// Checks for updates and manages the update state.
class UpdateChecker {
  UpdateChecker({
    required this.currentVersion,
    MemoryUpdatePreferences? preferences,
    GitHubReleaseFetcher? fetcher,
  })  : preferences = preferences ?? MemoryUpdatePreferences(),
        fetcher = fetcher ?? GitHubReleaseFetcher();

  /// Creates an UpdateChecker with explicit settings.
  UpdateChecker.simple({
    required String currentVersion,
    bool includePreReleases = false,
    GitHubReleaseFetcher? fetcher,
  })  : currentVersion = currentVersion,
        preferences = MemoryUpdatePreferences(includePreReleases: includePreReleases),
        fetcher = fetcher ?? GitHubReleaseFetcher();

  final String currentVersion;
  final UpdatePreferences preferences;
  final ReleaseFetcher fetcher;

  /// Whether an update check is currently in progress.
  bool _checking = false;

  /// The result of the last update check.
  UpdateCheckResult? _lastResult;

  /// Whether an update is available.
  bool get isUpdateAvailable => _lastResult?.available ?? false;

  /// The available release, if any.
  GitHubRelease? get availableRelease => _lastResult?.release;

  /// The error from the last check, if any.
  String? get lastError => _lastResult?.error;

  /// The last check time.
  DateTime? get lastCheckTime => _lastResult?.lastCheckTime;

  /// Whether we should check for updates (setting is on, and it's been long enough).
  bool get shouldCheck =>
      preferences.checkForUpdates &&
      (_lastResult?.lastCheckTime == null ||
          DateTime.now().difference(_lastResult!.lastCheckTime!) >= _checkInterval);

  /// Checks for updates.
  ///
  /// Returns the result of the check. If [force] is true, it checks even if
  /// the interval hasn't elapsed.
  Future<UpdateCheckResult> checkForUpdates({bool force = false}) async {
    // Don't check if we're already checking
    if (_checking && !force) {
      return _lastResult ?? const UpdateCheckResult();
    }

    _checking = true;

    try {
      // If not forcing and we shouldn't check, return the last result
      if (!force && !shouldCheck) {
        return _lastResult ?? const UpdateCheckResult();
      }

      final now = DateTime.now();

      // Check if we're offline
      if (!kIsWeb) {
        try {
          final result = await InternetAddress.lookup('github.com');
          if (result.isEmpty) {
            _lastResult = UpdateCheckResult(
              available: false,
              error: 'Offline',
              lastCheckTime: now,
            );
            await preferences.setLastCheckTime(now);
            _checking = false;
            return _lastResult!;
          }
        } on SocketException {
          _lastResult = UpdateCheckResult(
            available: false,
            error: 'Offline',
            lastCheckTime: now,
          );
          await preferences.setLastCheckTime(now);
          _checking = false;
          return _lastResult!;
        }
      }

      GitHubRelease? release;

      if (preferences.includePreReleases) {
        // Get all releases and find the newest
        final allReleases = await fetcher.fetchAllReleases();
        release = _findNewestRelease(allReleases);
      } else {
        // Get the latest full release
        release = await fetcher.fetchLatestRelease();
      }

      if (release == null) {
        _lastResult = UpdateCheckResult(
          available: false,
          error: 'Could not fetch release information',
          lastCheckTime: now,
        );
      } else if (isNewerVersion(release.version, currentVersion)) {
        _lastResult = UpdateCheckResult(
          available: true,
          release: release,
          lastCheckTime: now,
        );
        await preferences.setLastSeenVersion(release.version);
      } else {
        _lastResult = UpdateCheckResult(
          available: false,
          lastCheckTime: now,
        );
      }

      await preferences.setLastCheckTime(now);

      return _lastResult!;
    } catch (e) {
      _lastResult = UpdateCheckResult(
        available: false,
        error: e.toString(),
        lastCheckTime: DateTime.now(),
      );
      await preferences.setLastCheckTime(DateTime.now());
      return _lastResult!;
    } finally {
      _checking = false;
    }
  }

  /// Finds the newest release from a list.
  GitHubRelease? _findNewestRelease(List<GitHubRelease> releases) {
    if (releases.isEmpty) return null;

    GitHubRelease? newest;
    for (final release in releases) {
      if (newest == null) {
        newest = release;
      } else if (isNewerVersion(release.version, newest.version)) {
        newest = release;
      }
    }
    return newest;
  }

  /// Extracts the changelog entries since the current version.
  ///
  /// Returns the entries that are newer than the current version.
  List<String> getChangelogSinceCurrent(String changelog) {
    final entries = <String>[];
    final current = currentVersion;

    // Parse changelog entries (format: "## YYYY-MM-DD: title")
    final lines = changelog.split('\n');
    String? currentEntry;

    for (final line in lines) {
      if (line.startsWith('## ')) {
        // Save the previous entry if it's newer
        if (currentEntry != null && currentEntry.isNotEmpty) {
          final entryVersion = _extractVersionFromChangelogEntry(currentEntry);
          if (entryVersion != null && isNewerVersion(entryVersion, current)) {
            entries.add(currentEntry);
          }
        }
        currentEntry = line.substring(3).trim();
      } else if (currentEntry != null) {
        currentEntry += '\n$line';
      }
    }

    // Don't forget the last entry
    if (currentEntry != null && currentEntry.isNotEmpty) {
      final entryVersion = _extractVersionFromChangelogEntry(currentEntry);
      if (entryVersion != null && isNewerVersion(entryVersion, current)) {
        entries.add(currentEntry);
      }
    }

    return entries;
  }

  /// Extracts the version from a changelog entry heading.
  ///
  /// Expected format: "YYYY-MM-DD: title (vX.Y.Z)" or similar.
  String? _extractVersionFromChangelogEntry(String entry) {
    final heading = entry.split('\n').first;
    // Look for version in parentheses at the end
    final match = RegExp(r'\(v?([0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.]+)*)\)').firstMatch(heading);
    if (match != null) {
      return match.group(1);
    }
    // Look for version at the start
    final versionMatch = RegExp(r'v?([0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.]+)*)').firstMatch(heading);
    return versionMatch?.group(1);
  }

  /// Checks if the app was installed via install.sh.
  ///
  /// Returns true if install.sh exists next to the executable.
  static Future<bool> isInstalledViaInstallSh() async {
    if (!isDesktop) return false;

    try {
      final executable = Platform.resolvedExecutable;
      final executableDir = path.dirname(executable);
      final installSh = path.join(executableDir, 'install.sh');
      return await File(installSh).exists();
    } catch (_) {
      return false;
    }
  }

  /// Runs the install.sh update command.
  ///
  /// Returns the output of the command.
  static Future<ProcessResult> runInstallShUpdate() async {
    final executable = Platform.resolvedExecutable;
    final executableDir = path.dirname(executable);
    final installSh = path.join(executableDir, 'install.sh');

    return await Process.run(installSh, ['--update']);
  }
}
