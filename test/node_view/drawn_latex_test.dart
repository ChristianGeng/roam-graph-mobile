import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_tex_js/flutter_tex_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:katex/katex.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/drawn_latex.dart';
import 'package:roam_graph_mobile/node_view/latex.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf;

// Synthetic formulas (decision 14: no real notes in tests).
final _fixture = File('test/fixtures/latex.org').readAsStringSync();
const _id = '11111111-1111-4111-8111-000000000300';

/// The LaTeX blocks of the fixture: 13, of which one is broken.
const _blocks = 13;

/// The block of [text], parsed.
OrgLatexBlock blockOf(String text) {
  OrgLatexBlock? found;
  withDisplayFormulas(OrgDocument.parse(text)).visit<OrgLatexBlock>((block) {
    found = block;
    return false;
  });
  return found!;
}

List<FormulaLink> formulaLinks(OrgDocument document) {
  final found = <FormulaLink>[];
  document.visit<OrgLink>((link) {
    if (link is FormulaLink) found.add(link);
    return true;
  });
  return found;
}

/// The desktop platforms, where the app draws LaTeX blocks itself.
final desktop = TargetPlatformVariant.desktop();

void main() {
  group('the environment rewrite', () {
    test('a display formula, equation and equation* become the formula', () {
      expect(formulaToDraw(blockOf(r'\[ x^2 \]')), ' x^2 ');
      expect(
        formulaToDraw(blockOf('\\begin{equation}\nx\n\\end{equation}\n')),
        '\nx\n',
      );
      expect(
        formulaToDraw(blockOf('\\begin{equation*}\nx\n\\end{equation*}\n')),
        '\nx\n',
      );
    });

    test('align becomes aligned', () {
      expect(
        formulaToDraw(blockOf('\\begin{align}\na &= b\n\\end{align}\n')),
        '\\begin{aligned}\na &= b\n\\end{aligned}',
      );
    });

    test('gather and multline become array{c}', () {
      for (final environment in [
        'gather',
        'gather*',
        'multline',
        'multline*',
      ]) {
        expect(
          formulaToDraw(
            blockOf(
              '\\begin{$environment}\na \\\\\nb\n'
              '\\end{$environment}\n',
            ),
          ),
          '\\begin{array}{c}\na \\\\\nb\n\\end{array}',
          reason: environment,
        );
      }
    });

    test('other environments are passed as they are', () {
      for (final environment in ['align*', 'pmatrix', 'cases']) {
        final text = '\\begin{$environment}\na & b\n\\end{$environment}';
        expect(formulaToDraw(blockOf('$text\n')), text, reason: environment);
      }
    });

    test('labels and numbering commands are removed', () {
      expect(
        formulaToDraw(
          blockOf(
            '\\begin{equation}\nx \\label{eq:x}\n'
            '\\end{equation}\n',
          ),
        ),
        '\nx \n',
      );
      expect(
        formulaToDraw(
          blockOf(
            '\\begin{align}\na &= b \\nonumber \\\\\n'
            'c &= d \\notag\n\\end{align}\n',
          ),
        ),
        '\\begin{aligned}\na &= b  \\\\\nc &= d \n\\end{aligned}',
      );
    });

    test('every rewritten formula of the fixture can be laid out', () {
      final document = withDisplayFormulas(OrgDocument.parse(_fixture));
      final failed = <String>[];
      document.visit<OrgLatexBlock>((block) {
        final tex = formulaToDraw(block);
        if (layOutFormula(tex).box == null) failed.add(tex.trim());
        return true;
      });
      expect(failed, [r'\unknowncommand{x}']);
    });
  });

  group('which formulas are drawn by the app', () {
    testWidgets('every LaTeX block on the desktop', (tester) async {
      final document = withDrawnFormulas(
        withDisplayFormulas(OrgDocument.parse(_fixture)),
      );
      expect(formulaLinks(document), hasLength(_blocks));
      expect(document.find<OrgLatexBlock>((_) => true), isNull);
      // Inline formulas stay as they are (#300 step 2).
      expect(document.find<OrgLatexInline>((_) => true), isNotNull);
      // The search inside the note still finds a formula's source.
      expect(
        document.find<OrgParagraph>(
          (paragraph) => paragraph.contains(r'\nabla \cdot'),
        ),
        isNotNull,
      );
    }, variant: desktop);

    testWidgets('nothing on Android', (tester) async {
      final document = withDisplayFormulas(OrgDocument.parse(_fixture));
      expect(withDrawnFormulas(document), same(document));
    });

    testWidgets('nothing in a note with #+STARTUP: noinlineimages', (
      tester,
    ) async {
      final document = withDisplayFormulas(
        OrgDocument.parse('#+STARTUP: noinlineimages\n\n\\[ x \\]\n'),
      );
      expect(withDrawnFormulas(document), same(document));
    }, variant: desktop);

    testWidgets('a link the note writes with the location stays a link', (
      tester,
    ) async {
      final document = withDrawnFormulas(
        OrgDocument.parse('[[latex-formula.png]]\n'),
      );
      document.visit<OrgLink>((link) {
        expect(loadDrawnFormula(link), isNull);
        return true;
      });
    }, variant: desktop);
  });

  group('the node view', () {
    /// flutter_tex_js's channel, which the inline formulas (and on
    /// Android the blocks) still use; widget tests have no WebView.
    late List<Map<Object?, Object?>> texRenders;
    final png = File('test/fixtures/images/red-40x20.png').readAsBytesSync();

    setUp(() {
      texRenders = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_tex_js'), (
            call,
          ) async {
            if (call.method != 'render') return null;
            texRenders.add(call.arguments as Map<Object?, Object?>);
            return png;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter_tex_js'),
            null,
          );
    });

    Future<void> show(
      WidgetTester tester, {
      Brightness brightness = Brightness.light,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: NodeScreen(
            graph: ValueNotifier(graphOf({'latex.org': _fixture})),
            id: _id,
            readNote: (path) async => _fixture,
            nodeMemory: MemoryNodeMemory(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Iterable<KatexBoxPainter> painters(WidgetTester tester) => tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(DrawnFormula),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((paint) => paint.painter)
        .whereType<KatexBoxPainter>();

    testWidgets('on the desktop the app draws the blocks', (tester) async {
      await show(tester);
      expect(find.byType(DrawnFormula), findsNWidgets(_blocks));
      expect(painters(tester), hasLength(_blocks - 1));
      expect(find.byType(OrgLatexBlockWidget), findsNothing);
      // Only the inline formula goes to flutter_tex_js.
      expect(find.byType(OrgLatexInlineWidget), findsOneWidget);
      expect([
        for (final render in texRenders) render['displayMode'],
      ], everyElement(isFalse));
      expect(tester.takeException(), isNull);
    }, variant: desktop);

    testWidgets('on Android flutter_tex_js draws them, as before', (
      tester,
    ) async {
      await show(tester);
      expect(find.byType(DrawnFormula), findsNothing);
      expect(find.byType(OrgLatexBlockWidget), findsNWidgets(_blocks));
      expect(find.byType(TexImage), findsNWidgets(_blocks + 1));
    });

    testWidgets('a formula has the text colour and KaTeX\'s size, '
        'also in the dark theme', (tester) async {
      Future<(Color, double, double)> drawn(Brightness brightness) async {
        await show(tester, brightness: brightness);
        final painter = painters(tester).first;
        final text = DefaultTextStyle.of(
          tester.element(find.byType(DrawnFormula).first),
        ).style;
        expect(painters(tester).map((p) => p.color).toSet(), {painter.color});
        expect(painter.color, text.color);
        return (painter.color, painter.fontSize, text.fontSize!);
      }

      final (light, size, textSize) = await drawn(Brightness.light);
      expect(size, closeTo(textSize * 1.21, 0.001));
      expect(light.computeLuminance(), lessThan(0.2));
      final (dark, _, _) = await drawn(Brightness.dark);
      expect(dark.computeLuminance(), greaterThan(0.5));
    }, variant: desktop);

    testWidgets('a formula that cannot be drawn shows its source as text', (
      tester,
    ) async {
      await show(tester);
      final source = find.descendant(
        of: find.byType(DrawnFormula),
        matching: find.text(r'\[ \unknowncommand{x} \]'),
      );
      expect(source, findsOneWidget);
      final text = tester.widget<Text>(source);
      // In the text style, not in KaTeX's error red.
      expect(text.style, isNull);
      expect(
        DefaultTextStyle.of(tester.element(source)).style.color,
        isNot(const Color(0xFFCC0000)),
      );
      expect(tester.takeException(), isNull);
    }, variant: desktop);

    testWidgets('a wide formula scrolls sideways', (tester) async {
      await show(tester);
      final wide = find
          .byWidgetPredicate(
            (widget) => widget is DrawnFormula && widget.tex.contains('a_{24}'),
          )
          .first;
      await tester.ensureVisible(wide);
      await tester.pumpAndSettle();
      final scroll = find.descendant(
        of: wide,
        matching: find.byType(SingleChildScrollView),
      );
      expect(
        tester.widget<SingleChildScrollView>(scroll).scrollDirection,
        Axis.horizontal,
      );
      final paint = find.descendant(
        of: wide,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is KatexBoxPainter,
        ),
      );
      expect(
        tester.getSize(paint).width,
        greaterThan(tester.getSize(scroll).width),
      );
      expect(tester.takeException(), isNull);
    }, variant: desktop);
  });

  test('laid-out formulas are kept by their text', () {
    expect(
      layOutFormula(r'\frac{a}{b}').box,
      same(layOutFormula(r'\frac{a}{b}').box),
    );
  });
}
