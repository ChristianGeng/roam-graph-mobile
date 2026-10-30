import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/node_view/web_links.dart' show UrlOpener;
import 'package:roam_graph_mobile/settings/about_screen.dart';

import 'settings_screen_test.dart' show pumpSettings, top;

/// A bundle with a synthetic CHANGELOG.md, or none at all.
class FakeBundle extends AssetBundle {
  FakeBundle(this.changelog);

  final String? changelog;

  @override
  Future<ByteData> load(String key) async {
    final text = changelog;
    if (key != 'CHANGELOG.md' || text == null) {
      throw StateError('No asset "$key".');
    }
    final bytes = Uint8List.fromList(utf8.encode(text));
    return ByteData.sublistView(bytes);
  }
}

/// A changelog with [count] entries, the newest first: "Entry 1" is the
/// newest.
String syntheticChangelog(int count) {
  final text = StringBuffer('# Changelog\n\nSynthetic text before the entries.\n');
  for (var i = 1; i <= count; i++) {
    text.write('\n## 2026-01-${(31 - i % 28).toString().padLeft(2, '0')}: '
        'Entry $i ([#$i](https://example.com/pull/$i))\n\n'
        'Added: line of entry $i.\nCloses #$i.\n');
  }
  return text.toString();
}

void main() {
  group('versionLabel', () {
    test('a release is the plain version', () {
      expect(versionLabel('0.3.0'), 'Version 0.3.0');
    });

    test('a -dev. version is a pre-release', () {
      expect(versionLabel('0.2.0-dev.473'),
          'Version 0.2.0-dev.473 (pre-release)');
    });

    test('a local build shows dev', () {
      expect(versionLabel('dev'), 'Version dev');
    });
  });

  group('parseChangelog', () {
    test('takes the headings and bodies, and leaves out the preamble', () {
      final entries = parseChangelog(syntheticChangelog(2));
      expect(entries, hasLength(2));
      expect(entries.first.heading,
          startsWith('2026-01-30: Entry 1 (#1)'));
      expect(entries.first.body, 'Added: line of entry 1.\nCloses #1.');
    });

    test('an empty file has no entries', () {
      expect(parseChangelog(''), isEmpty);
    });
  });

  group('the About row (#207)', () {
    testWidgets('is the last row, with the version', (tester) async {
      await pumpSettings(tester, version: '0.2.0');
      expect(find.text('About'), findsOneWidget);
      expect(find.text('Version 0.2.0'), findsOneWidget);
      expect(top(tester, 'settings-about'),
          greaterThan(top(tester, 'settings-image-folder')));
    });

    testWidgets('says pre-release for a -dev. version', (tester) async {
      await pumpSettings(tester, version: '0.2.0-dev.473');
      expect(find.text('Version 0.2.0-dev.473 (pre-release)'),
          findsOneWidget);
    });

    testWidgets('a local build shows dev', (tester) async {
      await pumpSettings(tester);
      expect(find.text('Version dev'), findsOneWidget);
    });
  });

  group('the About page (#207)', () {
    Future<void> pumpAbout(
      WidgetTester tester, {
      String version = '0.2.0-dev.473',
      String? changelog,
      UrlOpener? openUrl,
    }) async {
      await pumpSettings(tester,
          version: version,
          bundle: FakeBundle(changelog ?? syntheticChangelog(25)),
          openUrl: openUrl);
      await tester.tap(find.byKey(const ValueKey('settings-about')));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the version and the newest entry', (tester) async {
      await pumpAbout(tester);
      expect(find.byKey(const ValueKey('about-version')), findsOneWidget);
      expect(find.text('Version 0.2.0-dev.473 (pre-release)'),
          findsAtLeastNWidgets(1));
      expect(find.textContaining('Entry 1 (#1)'), findsOneWidget);
      expect(find.text('Added: line of entry 1.\nCloses #1.'), findsOneWidget);
    });

    testWidgets('shows 20 entries, and "Show more" shows the rest',
        (tester) async {
      await pumpAbout(tester);
      expect(find.textContaining('Entry 20 (#20)'), findsOneWidget);
      expect(find.textContaining('Entry 21 (#21)'), findsNothing);
      final more = find.byKey(const ValueKey('about-show-more'));
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.textContaining('Entry 25 (#25)'), findsOneWidget);
      expect(find.byKey(const ValueKey('about-show-more')), findsNothing);
    });

    testWidgets('no "Show more" for a short changelog', (tester) async {
      await pumpAbout(tester, changelog: syntheticChangelog(3));
      expect(find.byKey(const ValueKey('about-show-more')), findsNothing);
    });

    testWidgets('says so when the changelog cannot be read', (tester) async {
      await pumpSettings(tester, bundle: FakeBundle(null));
      await tester.tap(find.byKey(const ValueKey('settings-about')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('about-changelog-error')),
          findsOneWidget);
    });

    testWidgets('the copy icon copies the version', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpAbout(tester);
      await tester.tap(find.byKey(const ValueKey('about-copy-version')));
      await tester.pump();
      expect(copied, 'Version 0.2.0-dev.473 (pre-release)');
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('the link opens the releases page', (tester) async {
      final opened = <Uri>[];
      await pumpAbout(tester, openUrl: (uri) async {
        opened.add(uri);
        return true;
      });
      await tester.tap(find.byKey(const ValueKey('about-releases')));
      await tester.pump();
      expect(opened, [
        Uri.parse('https://github.com/ChristianGeng/roam-graph-mobile/releases')
      ]);
    });

    testWidgets('"Licences" opens the licence page', (tester) async {
      await pumpAbout(tester);
      await tester.tap(find.byKey(const ValueKey('about-licences')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LicensePage), findsOneWidget);
    });
  });
}
