// The version of a build, from the repository's releases (#167, decision
// 100), and the release whose CHANGELOG.md the release notes compare with.
//
//   dart tool/release_version.dart RELEASES RUN STARTED [--full]
//       [--bump patch|minor|major] [--version X.Y.Z]
//
// RELEASES is a file with the output of
// `gh release list --exclude-drafts --json tagName,isPrerelease,createdAt`.
// RUN is the run number. STARTED is when the version job of the run's
// first attempt started: releases made then or later (by this run, or by a
// later run when an old run is run again) are left out, so a re-run gets
// the version of the first attempt.
//
// Without --full: a pre-release, the next patch version with the suffix
// -dev.RUN. With --full: a full release, the last full release raised by
// --bump (default minor), or --version, which must be higher.
//
// Prints "name=<version>" and "previous=<tag>" (empty if there is none),
// the lines the version job in .github/workflows/build.yml writes to
// $GITHUB_OUTPUT.

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln('Usage: dart tool/release_version.dart RELEASES RUN '
        'STARTED [--full] [--bump patch|minor|major] [--version X.Y.Z]');
    exit(2);
  }
  try {
    stdout.write(releaseOutputs(
        File(args[0]).readAsStringSync(), args[1], args[2], args.sublist(3)));
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(1);
  }
}

/// A semantic version `major.minor.patch`, with `-dev.<run>` for a
/// pre-release.
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch, {this.dev});

  final int major;
  final int minor;
  final int patch;

  /// The run number of a pre-release, null for a full release.
  final int? dev;

  static final _pattern =
      RegExp(r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-dev\.(0|[1-9]\d*))?$');

  /// The version of [text] (`0.2.0`, `v0.2.1-dev.412`), or null.
  static Version? tryParse(String text) {
    final match = _pattern.firstMatch(text);
    if (match == null) return null;
    final dev = match.group(4);
    return Version(int.parse(match.group(1)!), int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        dev: dev == null ? null : int.parse(dev));
  }

  /// A release `v0.1.<run>`, from before the semantic versions. They count
  /// as full releases, all lower than 0.2.0.
  bool get isOld => major == 0 && minor <= 1 && dev == null;

  /// Semantic versioning's order: `0.2.1-dev.412` is lower than `0.2.1`.
  @override
  int compareTo(Version other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    if (dev == other.dev) return 0;
    if (dev == null) return 1;
    if (other.dev == null) return -1;
    return dev!.compareTo(other.dev!);
  }

  bool operator >(Version other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, dev);

  @override
  String toString() =>
      '$major.$minor.$patch${dev == null ? '' : '-dev.$dev'}';
}

/// A published release.
class Release {
  const Release(this.tag, this.version, {required this.prerelease});

  final String tag;
  final Version version;
  final bool prerelease;
}

/// The releases in [json] (from `gh release list`) made before [before].
///
/// A full release is one not marked as pre-release with a tag
/// `vX.Y.Z`; a pre-release is one marked as pre-release with a tag
/// `vX.Y.Z-dev.N`. Other releases and tags are left out.
List<Release> readReleases(String json, {DateTime? before}) {
  final releases = <Release>[];
  for (final item in (jsonDecode(json) as List).cast<Map<String, dynamic>>()) {
    final version = Version.tryParse(item['tagName'] as String);
    final prerelease = item['isPrerelease'] as bool;
    final created = DateTime.parse(item['createdAt'] as String);
    if (version == null || prerelease != (version.dev != null)) continue;
    if (before != null && !created.isBefore(before)) continue;
    releases.add(
        Release(item['tagName'] as String, version, prerelease: prerelease));
  }
  return releases;
}

Release? _highest(Iterable<Release> releases) {
  Release? highest;
  for (final release in releases) {
    if (highest == null || release.version > highest.version) {
      highest = release;
    }
  }
  return highest;
}

/// The last full release: the one with the highest version.
Release? lastFullRelease(List<Release> releases) =>
    _highest(releases.where((release) => !release.prerelease));

/// The release whose changelog the notes compare with: for a full release
/// the last full release, so the notes hold everything merged since; for
/// a pre-release the last release of either kind.
Release? previousRelease(List<Release> releases, {required bool full}) =>
    full ? lastFullRelease(releases) : _highest(releases);

const bumps = ['patch', 'minor', 'major'];

/// The version of build [run].
///
/// A pre-release is the next patch version after the last full release,
/// with `-dev.<run>`. A full release is the last full release raised by
/// [bump], or [version], which must be higher. After the old `v0.1.<run>`
/// releases (or none), the next version is 0.2.0: a pre-release
/// `0.2.0-dev.<run>`, a full release 0.2.0 (patch or minor) or 1.0.0
/// (major).
///
/// Throws a [FormatException] for a wrong [bump] or [version].
Version nextVersion(List<Release> releases,
    {required bool full, required int run, String bump = 'minor', String? version}) {
  final last = lastFullRelease(releases)?.version;
  final old = last == null || last.isOld;
  if (!full) {
    return old
        ? Version(0, 2, 0, dev: run)
        : Version(last.major, last.minor, last.patch + 1, dev: run);
  }
  if (version != null && version.isNotEmpty) {
    final chosen = Version.tryParse(version);
    if (chosen == null || chosen.dev != null) {
      throw FormatException(
          'The version "$version" is not of the form 1.2.3.');
    }
    if (chosen.isOld) {
      throw FormatException('The version $chosen is not higher than the old '
          'releases v0.1.<run>: the first one is 0.2.0 or higher.');
    }
    if (last != null && !(chosen > last)) {
      throw FormatException(
          'The version $chosen is not higher than the last full release, $last.');
    }
    return chosen;
  }
  if (!bumps.contains(bump)) {
    throw FormatException(
        'The bump "$bump" is not one of ${bumps.join(', ')}.');
  }
  if (old) return bump == 'major' ? const Version(1, 0, 0) : const Version(0, 2, 0);
  return switch (bump) {
    'major' => Version(last.major + 1, 0, 0),
    'minor' => Version(last.major, last.minor + 1, 0),
    _ => Version(last.major, last.minor, last.patch + 1),
  };
}

/// The output of the command line: [json] is the release list, [args] the
/// options after RUN and STARTED.
String releaseOutputs(
    String json, String run, String started, List<String> args) {
  final number = int.tryParse(run);
  if (number == null || number < 1) {
    throw FormatException('The run number "$run" is not a number.');
  }
  final before = DateTime.tryParse(started);
  if (before == null) {
    throw FormatException('"$started" is not a time.');
  }
  var full = false;
  var bump = 'minor';
  String? version;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--full':
        full = true;
      case '--bump' when i + 1 < args.length:
        bump = args[++i];
      case '--version' when i + 1 < args.length:
        version = args[++i];
      default:
        throw FormatException('Unknown option "${args[i]}".');
    }
  }
  final releases = readReleases(json, before: before);
  final name = nextVersion(releases,
      full: full, run: number, bump: bump, version: version);
  final previous = previousRelease(releases, full: full);
  return 'name=$name\nprevious=${previous?.tag ?? ''}\n';
}
