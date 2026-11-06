// ~code~ and =verbatim= in a monospace font (#238).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/org_fonts.dart';

/// Every text span on screen with its text, and its style merged from
/// the outer spans.
List<(String, TextStyle)> spans(WidgetTester tester) {
  final found = <(String, TextStyle)>[];
  void walk(InlineSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    if (span is TextSpan) {
      if (span.text != null && span.text!.isNotEmpty) {
        found.add((span.text!, style));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child, style);
      }
    }
  }

  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rich.text, const TextStyle());
  }
  return found;
}

TextStyle styleOf(WidgetTester tester, String text) =>
    spans(tester).firstWhere((s) => s.$1.contains(text)).$2;

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('~code~ and =verbatim= are monospace, the text around not', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MonospaceOrgText(
            'Set ~BRAVE_API_KEY~ in =config.yaml= and plain words.',
          ),
        ),
      ),
    );
    expect(styleOf(tester, 'BRAVE_API_KEY').fontFamily, 'monospace');
    expect(styleOf(tester, 'config.yaml').fontFamily, 'monospace');
    expect(
      styleOf(tester, 'BRAVE_API_KEY').fontFamilyFallback,
      monospaceFallback,
    );
    expect(styleOf(tester, 'plain words').fontFamily, isNot('monospace'));
    expect(styleOf(tester, 'Set').fontFamily, isNot('monospace'));
  });

  testWidgets('the code colour of org_flutter stays', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MonospaceOrgText('a ~code~ b'))),
    );
    expect(styleOf(tester, 'code').color, OrgThemeData.light().codeColor);
  });

  test('bold, italic and the rest are unchanged', () {
    const base = TextStyle(fontFamily: 'Roboto');
    final theme = MonospaceOrgThemeData.light;
    for (final style in OrgStyle.values) {
      final ours = theme.fontStyleForOrgStyle(base, style);
      final theirs = OrgThemeData.light().fontStyleForOrgStyle(base, style);
      if (style == OrgStyle.code || style == OrgStyle.verbatim) {
        expect(ours.fontFamily, monospaceFamily, reason: '$style');
        expect(ours.color, theirs.color, reason: '$style');
      } else {
        expect(ours, theirs, reason: '$style');
      }
    }
  });

  test('the monospace font of each platform', () {
    const fonts = {
      TargetPlatform.android: 'monospace',
      TargetPlatform.linux: 'monospace',
      TargetPlatform.macOS: 'Menlo',
      TargetPlatform.windows: 'Consolas',
    };
    for (final MapEntry(key: platform, value: font) in fonts.entries) {
      debugDefaultTargetPlatformOverride = platform;
      expect(monospaceFamily, font, reason: '$platform');
      expect(
        MonospaceOrgThemeData.dark
            .fontStyleForOrgStyle(const TextStyle(), OrgStyle.code)
            .fontFamily,
        font,
        reason: '$platform',
      );
    }
  });

  test('every colour of the base theme is kept', () {
    final base = OrgThemeData.dark();
    final ours = MonospaceOrgThemeData(base);
    expect(ours.codeColor, base.codeColor);
    expect(ours.linkColor, base.linkColor);
    expect(ours.levelColors, base.levelColors);
    expect(ours.srcTheme, base.srcTheme);
    expect(ours.rootPadding, base.rootPadding);
    expect(MonospaceOrgThemeData.lightTight.rootPadding, EdgeInsets.zero);
  });
}
