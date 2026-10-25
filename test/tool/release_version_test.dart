import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_version.dart';

String _json(List<(String, bool, String)> releases) => jsonEncode([
      for (final (tag, prerelease, created) in releases)
        {'tagName': tag, 'isPrerelease': prerelease, 'createdAt': created},
    ]);

List<Release> _releases(List<(String, bool)> releases) => readReleases(_json([
      for (final (tag, prerelease) in releases)
        (tag, prerelease, '2026-10-01T00:00:00Z'),
    ]));

void main() {
  final old = _releases([('v0.1.374', false), ('v0.1.370', false)]);
  final semantic = _releases([
    ('v0.2.1-dev.420', true),
    ('v0.2.0', false),
    ('v0.2.0-dev.380', true),
    ('v0.1.374', false),
  ]);

  group('a full release', () {
    test('raises the last full release by the bump', () {
      expect(nextVersion(semantic, full: true, run: 421, bump: 'patch'),
          const Version(0, 2, 1));
      expect(nextVersion(semantic, full: true, run: 421, bump: 'minor'),
          const Version(0, 3, 0));
      expect(nextVersion(semantic, full: true, run: 421, bump: 'major'),
          const Version(1, 0, 0));
    });

    test('raises the minor version without a bump', () {
      expect(nextVersion(semantic, full: true, run: 421),
          const Version(0, 3, 0));
    });

    test('a minor or major bump sets the lower numbers to 0', () {
      final releases = _releases([('v1.4.2', false)]);
      expect(nextVersion(releases, full: true, run: 9, bump: 'minor'),
          const Version(1, 5, 0));
      expect(nextVersion(releases, full: true, run: 9, bump: 'major'),
          const Version(2, 0, 0));
    });

    test('compares the numbers, not the text', () {
      final releases = _releases([('v0.9.0', false), ('v0.10.0', false)]);
      expect(nextVersion(releases, full: true, run: 9, bump: 'patch'),
          const Version(0, 10, 1));
    });

    test('takes a higher version instead of the bump', () {
      expect(
          nextVersion(semantic,
              full: true, run: 421, bump: 'patch', version: '1.0.0'),
          const Version(1, 0, 0));
      expect(nextVersion(semantic, full: true, run: 421, version: 'v0.2.5'),
          const Version(0, 2, 5));
    });

    test('an empty version means the bump', () {
      expect(nextVersion(semantic, full: true, run: 421, version: ''),
          const Version(0, 3, 0));
    });

    test('refuses a version that is not higher than the last full release',
        () {
      for (final version in ['0.2.0', '0.1.999', '0.0.1']) {
        expect(
            () => nextVersion(semantic,
                full: true, run: 421, version: version),
            throwsFormatException,
            reason: version);
      }
    });

    test('refuses a version that is not X.Y.Z', () {
      for (final version in ['1.0', '1.0.0-dev.3', '1.0.0-beta', 'x', '01.0.0']) {
        expect(
            () => nextVersion(semantic,
                full: true, run: 421, version: version),
            throwsFormatException,
            reason: version);
      }
    });

    test('refuses an unknown bump', () {
      expect(() => nextVersion(semantic, full: true, run: 421, bump: 'big'),
          throwsFormatException);
    });
  });

  group('a pre-release', () {
    test('is the next patch version with -dev.<run>', () {
      expect(nextVersion(semantic, full: false, run: 421).toString(),
          '0.2.1-dev.421');
    });

    test('ignores the bump and the version', () {
      expect(
          nextVersion(semantic,
              full: false, run: 421, bump: 'major', version: '5.0.0'),
          const Version(0, 2, 1, dev: 421));
    });

    test('sorts below the full release of its patch version', () {
      expect(const Version(0, 2, 1) > const Version(0, 2, 1, dev: 421),
          isTrue);
      expect(const Version(0, 2, 1, dev: 100) > const Version(0, 2, 1, dev: 99),
          isTrue);
      expect(const Version(0, 2, 1, dev: 421) > const Version(0, 2, 0),
          isTrue);
    });
  });

  group('the old v0.1.<run> releases', () {
    test('count as full releases before 0.2.0', () {
      expect(lastFullRelease(old)!.tag, 'v0.1.374');
      expect(lastFullRelease(semantic)!.tag, 'v0.2.0');
    });

    test('are followed by the pre-releases 0.2.0-dev.<run>', () {
      expect(nextVersion(old, full: false, run: 380).toString(),
          '0.2.0-dev.380');
    });

    test('are followed by 0.2.0, or by 1.0.0 for a major bump', () {
      expect(nextVersion(old, full: true, run: 380, bump: 'patch'),
          const Version(0, 2, 0));
      expect(nextVersion(old, full: true, run: 380, bump: 'minor'),
          const Version(0, 2, 0));
      expect(nextVersion(old, full: true, run: 380, bump: 'major'),
          const Version(1, 0, 0));
    });

    test('a version must be 0.2.0 or higher', () {
      expect(nextVersion(old, full: true, run: 380, version: '0.2.0'),
          const Version(0, 2, 0));
      expect(() => nextVersion(old, full: true, run: 380, version: '0.1.999'),
          throwsFormatException);
    });

    test('without any release, the first versions are those after them', () {
      expect(nextVersion([], full: false, run: 1).toString(), '0.2.0-dev.1');
      expect(nextVersion([], full: true, run: 1), const Version(0, 2, 0));
      expect(previousRelease([], full: true), isNull);
    });
  });

  group('the previous release for the notes', () {
    test('of a full release is the last full release', () {
      expect(previousRelease(semantic, full: true)!.tag, 'v0.2.0');
      expect(previousRelease(old, full: true)!.tag, 'v0.1.374');
    });

    test('of a pre-release is the last release of either kind', () {
      expect(previousRelease(semantic, full: false)!.tag, 'v0.2.1-dev.420');
      expect(
          previousRelease(
                  _releases([('v0.2.1-dev.420', true), ('v0.2.1', false)]),
                  full: false)!
              .tag,
          'v0.2.1');
      expect(previousRelease(old, full: false)!.tag, 'v0.1.374');
    });
  });

  group('the release list', () {
    test('leaves out other tags and releases marked as the other kind', () {
      final releases = _releases([
        ('v0.3.0-dev.500', false),
        ('v0.4.0', true),
        ('nightly', false),
        ('v0.2.0', false),
      ]);
      expect([for (final release in releases) release.tag], ['v0.2.0']);
    });

    test('leaves out the releases made since the run started', () {
      final releases = readReleases(
          _json([
            ('v0.3.0', false, '2026-10-20T10:00:00Z'),
            ('v0.2.0', false, '2026-10-20T09:00:00Z'),
            ('v0.1.374', false, '2026-10-19T09:00:00Z'),
          ]),
          before: DateTime.parse('2026-10-20T09:00:00Z'));
      expect([for (final release in releases) release.tag], ['v0.1.374']);
    });
  });

  group('the command line', () {
    final json = _json([
      ('v0.2.0', false, '2026-10-20T09:00:00Z'),
      ('v0.2.1-dev.420', true, '2026-10-21T09:00:00Z'),
    ]);
    const started = '2026-10-22T09:00:00Z';

    test('prints the name and the previous release', () {
      expect(releaseOutputs(json, '421', started, []),
          'name=0.2.1-dev.421\nprevious=v0.2.1-dev.420\n');
      expect(
          releaseOutputs(json, '421', started, ['--full', '--bump', 'patch']),
          'name=0.2.1\nprevious=v0.2.0\n');
      expect(
          releaseOutputs(json, '421', started,
              ['--full', '--bump', 'minor', '--version', '1.0.0']),
          'name=1.0.0\nprevious=v0.2.0\n');
    });

    test('a re-run of the run that made v0.2.0 gets 0.2.0 again', () {
      expect(
          releaseOutputs(json, '419', '2026-10-20T08:00:00Z', ['--full']),
          'name=0.2.0\nprevious=\n');
    });

    test('refuses wrong arguments', () {
      for (final (run, created, args) in [
        ('x', started, <String>[]),
        ('421', 'yesterday', <String>[]),
        ('421', started, ['--bump']),
        ('421', started, ['--fast']),
        ('421', started, ['--full', '--version', '0.1.0']),
      ]) {
        expect(() => releaseOutputs(json, run, created, args),
            throwsFormatException,
            reason: '$run $created $args');
      }
    });
  });
}
