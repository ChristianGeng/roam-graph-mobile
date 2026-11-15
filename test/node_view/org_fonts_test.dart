// Code, verbatim and blocks in a monospace font (#238, #239).
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/org_fonts.dart';

import 'node_screen_test.dart' show graphOf, open;

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

/// A synthetic note with every element org_flutter draws as code, and
/// the ones it does not.
const blocksNote =
    ':PROPERTIES:\n:ID: blocks\n:END:\n#+title: Blocks\n'
    'Body words with ~inline code~ and =inline verbatim= in them.\n\n'
    'Inline source: src_sh[:exports code]{echo inlinesrc}\n\n'
    '#+begin_src sh\nif [ -f x ]; then echo highlightedValue; fi\n#+end_src\n\n'
    '#+begin_src text\nplain language body\n#+end_src\n\n'
    '#+begin_src\nno language body\n#+end_src\n\n'
    '#+begin_example\nexample body\n#+end_example\n\n'
    '#+begin_export html\nexport body\n#+end_export\n\n'
    ': fixed width line\n\n'
    '#+begin_quote\nquote body\n#+end_quote\n\n'
    '#+begin_verse\nverse body\n#+end_verse\n';

/// Text in [blocksNote] that is monospace.
const monospaceNeedles = [
  'inline code',
  'inline verbatim',
  'echo inlinesrc',
  'highlightedValue',
  'plain language body',
  'no language body',
  'example body',
  'export body',
  'fixed width line',
];

/// Text in [blocksNote] that keeps the document's font.
const documentNeedles = ['Body words with', 'quote body', 'verse body'];

/// A tall window, so the whole note is built: it is in a scrolling list,
/// which builds only what is visible.
void tallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void expectMonospace(WidgetTester tester) {
  for (final needle in monospaceNeedles) {
    final style = styleOf(tester, needle);
    expect(style.fontFamily, 'monospace', reason: needle);
    expect(style.fontFamilyFallback, monospaceFallback, reason: needle);
  }
  for (final needle in documentNeedles) {
    expect(
      styleOf(tester, needle).fontFamily,
      isNot('monospace'),
      reason: needle,
    );
  }
}

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

  testWidgets('in the note view, blocks, fixed-width lines and inline '
      'source are monospace; quote, verse and body text are not (#239)', (
    tester,
  ) async {
    tallWindow(tester);
    await open(
      tester,
      'blocks',
      graph: ValueNotifier(graphOf({'blocks.org': blocksNote})),
      texts: const {'blocks.org': blocksNote},
    );
    expectMonospace(tester);
  });

  testWidgets('the same in the dark theme', (tester) async {
    tallWindow(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: OrgController(
            root: OrgDocument.parse(blocksNote),
            child: OrgRootWidget(
              lightTheme: MonospaceOrgThemes.light,
              darkTheme: MonospaceOrgThemes.dark,
              child: OrgDocumentWidget(OrgDocument.parse(blocksNote)),
            ),
          ),
        ),
      ),
    );
    expectMonospace(tester);
    // The dark theme is the one in use: its code colour.
    expect(
      styleOf(tester, 'example body').color,
      OrgThemeData.dark().codeColor,
    );
  });

  testWidgets('the same in a chat answer (MonospaceOrgText)', (tester) async {
    tallWindow(tester);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MonospaceOrgText(blocksNote)),
        ),
      ),
    );
    expectMonospace(tester);
  });

  testWidgets('blocks and fixed-width lines keep their colours (#239)', (
    tester,
  ) async {
    tallWindow(tester);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MonospaceOrgText(blocksNote)),
        ),
      ),
    );
    final light = OrgThemeData.light();
    for (final needle in [
      'example body',
      'export body',
      'fixed width line',
      'plain language body',
      'no language body',
    ]) {
      expect(styleOf(tester, needle).color, light.codeColor, reason: needle);
    }
    expect(styleOf(tester, 'sh').color, light.metaColor);
  });

  test('bold, italic and the rest are unchanged', () {
    const base = TextStyle(fontFamily: 'Roboto');
    final theme = MonospaceOrgThemes.light;
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
      final theme = MonospaceOrgThemes.dark;
      for (final style in [
        theme.codeTextStyle,
        theme.verbatimTextStyle,
        theme.blockTextStyle,
      ]) {
        expect(style?.fontFamily, font, reason: '$platform');
        expect(style?.fontFamilyFallback, monospaceFallback);
      }
    }
  });

  test('the three styles set only the font; every colour is kept', () {
    final base = OrgThemeData.dark();
    final ours = withMonospaceCode(base);
    for (final style in [
      ours.codeTextStyle,
      ours.verbatimTextStyle,
      ours.blockTextStyle,
    ]) {
      expect(style, monospaceTextStyle);
      expect(style?.color, isNull);
      expect(style?.fontSize, isNull);
    }
    expect(
      ours.copyWith(
        codeTextStyle: const TextStyle(),
        verbatimTextStyle: const TextStyle(),
        blockTextStyle: const TextStyle(),
      ),
      base.copyWith(
        codeTextStyle: const TextStyle(),
        verbatimTextStyle: const TextStyle(),
        blockTextStyle: const TextStyle(),
      ),
    );
    expect(ours.codeColor, base.codeColor);
    expect(ours.srcTheme, base.srcTheme);
    expect(MonospaceOrgThemes.lightTight.rootPadding, EdgeInsets.zero);
    expect(
      MonospaceOrgThemes.light.rootPadding,
      OrgThemeData.light().rootPadding,
    );
  });
}
