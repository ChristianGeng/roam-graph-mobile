import 'dart:io';

import 'package:flutter/rendering.dart' show RenderParagraph, SelectedContent;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/drawn_latex.dart';
import 'package:roam_graph_mobile/node_view/latex.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/org_fonts.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'latex_test.dart' show mu;
import 'node_screen_test.dart' show graphOf;

// Synthetic formulas (decision 14: no real notes in tests).
final _fixture = File('test/fixtures/latex.org').readAsStringSync();
const _id = '11111111-1111-4111-8111-000000000300';

/// The LaTeX blocks of the fixture: 15, of which one is broken; and one
/// inline formula.
const _blocks = 15;
const _broken = r'\[ \unknowncommand{x} \]';

/// The block of [text], parsed.
OrgLatexBlock blockOf(String text) {
  OrgLatexBlock? found;
  withDisplayFormulas(OrgDocument.parse(text)).visit<OrgLatexBlock>((block) {
    found = block;
    return false;
  });
  return found!;
}

/// The inline formula of [text], parsed.
OrgLatexInline inlineOf(String text) {
  OrgLatexInline? found;
  OrgDocument.parse(text).visit<OrgLatexInline>((inline) {
    found = inline;
    return false;
  });
  return found!;
}

/// The render objects of the formulas [formulas] finds, or of every
/// formula.
List<RenderFormula> drawn(WidgetTester tester, [Finder? formulas]) => tester
    .renderObjectList(formulas ?? find.byType(DrawnFormula))
    .map(
      (object) => switch (object) {
        final RenderFormula formula => formula,
        // Semantics sits above the formula's own render object.
        _ => _below<RenderFormula>(object),
      },
    )
    .toList();

T _below<T extends RenderObject>(RenderObject object) {
  T? found;
  void visit(RenderObject child) {
    if (found != null) return;
    if (child is T) {
      found = child;
    } else {
      child.visitChildren(visit);
    }
  }

  object.visitChildren(visit);
  return found!;
}

/// The style of the first text span that holds [text], merged with the
/// styles of the spans around it; null when no span holds it.
TextStyle? styleOfText(WidgetTester tester, String text) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    TextStyle? found;
    void visit(InlineSpan span, TextStyle? parent) {
      final style = parent?.merge(span.style) ?? span.style;
      if (span is TextSpan) {
        if (found == null && (span.text?.contains(text) ?? false)) {
          found = style;
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child, style);
        }
      }
    }

    visit(rich.text, null);
    if (found != null) return found;
  }
  return null;
}

void main() {
  // The layouts are kept in one cache for the whole app.
  setUp(forgetLaidOutFormulas);
  tearDown(forgetLaidOutFormulas);

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

    test('gather and multline become darray{c}, in display style', () {
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
          '\\begin{darray}{c}\na \\\\\nb\n\\end{darray}',
          reason: environment,
        );
      }
    });

    test('a removed label leaves the commands around it apart', () {
      final tex = formulaToDraw(
        blockOf(
          '\\begin{equation}\n\\pi\\label{eq:area}r^2\n\\end{equation}\n',
        ),
      );
      expect(tex, isNot(contains(r'\pir')));
      expect(layOutFormula(tex).box, isNotNull);
    });

    test('a row break before notag is kept', () {
      // \\\\notag is a row break followed by the letters notag, not \\notag.
      final tex = formulaToDraw(
        blockOf('\\begin{align}\na &= b \\\\notag &= c\n\\end{align}\n'),
      );
      expect(tex, contains(r'b \\notag'));
      // A real \\notag after a row break is still removed.
      final real = formulaToDraw(
        blockOf('\\begin{align}\na &= b \\\\\\notag\nc &= d\n\\end{align}\n'),
      );
      expect(real, isNot(contains('notag')));
      expect(real, contains(r'\\'));
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
        '\nx  \n',
      );
      expect(
        formulaToDraw(
          blockOf(
            '\\begin{align}\na &= b \\nonumber \\\\\n'
            'c &= d \\notag\n\\end{align}\n',
          ),
        ),
        '\\begin{aligned}\na &= b   \\\\\nc &= d  \n\\end{aligned}',
      );
    });

    test('every rewritten formula of the fixture can be laid out', () {
      final document = withDisplayFormulas(OrgDocument.parse(_fixture));
      final failed = <String>[];
      document.visit<OrgLatexBlock>((block) {
        final tex = formulaToDraw(block);
        if (layOutTagged(tex).box == null) failed.add(tex.trim());
        return true;
      });
      expect(failed, [r'\unknowncommand{x}']);
    });
  });

  group('tags', () {
    test('a tag is drawn after its formula, as text, else as math', () {
      expect(withDrawnTags(r'x \tag{N2}'), r'x \qquad\text{(N2)}');
      expect(withDrawnTags(r'x \tag*{A} '), r'x \qquad\text{A} ');
      expect(withDrawnTags(r'x \tag{a_b}'), r'x \qquad{(a_b)}');
      expect(
        withDrawnTags(r'a \tag{$b_{1}$} \\ c \tag {2^{n}}'),
        r'a \qquad\text{($b_{1}$)} \\ c \qquad{(2^{n})}',
      );
      expect(withDrawnTags(r'x \tag{1} = y', drop: true), 'x   = y');
    });

    test(
      'tags in math, in text and odd ones are laid out with the formula',
      () {
        double width(String tex) => layOutTagged(tex).box!.width;
        final plain = width('x = 1');
        for (final tag in [
          r'\tag{7}',
          r'\tag{a_b}',
          r'\tag{2^{n}}',
          r'\tag{\alpha}',
          r'\tag{$b_{1}$}',
          r'\tag{\text{a}}',
          r'\tag{1{.}2}',
          r'\tag*{a_b}',
          r'\tag*{$\alpha$}',
        ]) {
          expect(layOutTagged('x = 1 $tag').box, isNotNull, reason: tag);
          expect(width('x = 1 $tag'), greaterThan(plain), reason: tag);
        }
      },
    );

    test('each tag of an align is drawn its own way', () {
      final tagged = layOutTagged(
        r'\begin{aligned}p &= q \tag{a_b} \\ r &= s \tag*{$\alpha$}'
        r'\end{aligned}',
      ).box;
      final plain = layOutFormula(
        r'\begin{aligned}p &= q \\ r &= s\end{aligned}',
      ).box!;
      expect(tagged!.width, greaterThan(plain.width));
    });

    test('a tag that cannot be drawn leaves the formula drawn without it', () {
      // A tag that cannot be laid out alone is left out; the formula and
      // its other tags are drawn.
      final one = layOutTagged(r'x \tag{$\frac{1}$} = y \tag*{B}').box;
      expect(one, isNotNull);
      expect(one!.width, greaterThan(layOutFormula(r'x = y').box!.width));
      expect(layOutTagged(r'\text{see \tag{1}}').box, isNotNull);
      // A tag where no tag can stand (an array's column spec): the formula
      // without its tags.
      expect(
        layOutTagged(r'\begin{array}{c\tag{1}} x \end{array}').box,
        isNotNull,
      );
      // Not a tag at all: an error stays an error.
      expect(layOutTagged(r'\frac{1}{').box, isNull);
    });

    test('a row break before tag letters and a tag without its brace stay', () {
      expect(withDrawnTags(r'a \\tag{1}'), r'a \\tag{1}');
      expect(withDrawnTags(r'a \tag{1'), r'a \tag{1');
    });

    test('a tagged block is drawn with its tag', () {
      double width(String text) =>
          (loadLatexBlock(blockOf(text))! as DrawnFormula).box.width;
      for (final environment in ['equation', 'align', 'gather']) {
        expect(
          width('\\begin{$environment}\nx = 1 \\tag{7}\n\\end{$environment}\n'),
          greaterThan(
            width('\\begin{$environment}\nx = 1\n\\end{$environment}\n'),
          ),
          reason: environment,
        );
      }
      expect(width(r'\[ x \tag*{a} \]'), greaterThan(width(r'\[ x \]')));
    });

    test('an inline display formula is drawn with its tag', () {
      double width(String text) =>
          ((loadLatexInline(inlineOf(text))! as WidgetSpan).child
                  as DrawnFormula)
              .box
              .width;
      expect(width(r'A \[x \tag{1}\] b.'), greaterThan(width(r'A \[x\] b.')));
    });
  });

  group('#+ATTR_ORG: :align', () {
    Map<String, double> alignments(String text) {
      final document = withDisplayFormulas(OrgDocument.parse(text));
      return {
        for (final MapEntry(:key, :value) in latexAlignments(document).entries)
          key.content.trim(): value,
      };
    }

    test('places the block right after it', () {
      expect(
        alignments(
          '#+ATTR_ORG: :align center\n'
          '\\begin{equation}\na\n\\end{equation}\n\n'
          '#+ATTR_ORG: :align right\n'
          '\\[ b \\]\n\n'
          '#+ATTR_HTML: :center t\n'
          '\\[ c \\]\n\n'
          '#+ATTR_ORG: :align left\n'
          '#+ATTR_HTML: :align right\n'
          '\\[ d \\]\n\n'
          '\\[ e \\]\n',
        ),
        {'a': 0.5, 'b': 1.0, 'c': 0.5, 'd': 0.0},
      );
    });

    test('not after a blank line', () {
      expect(
        alignments(
          '#+ATTR_ORG: :align center\n\n'
          '\\begin{equation}\na\n\\end{equation}\n\n'
          '#+ATTR_ORG: :align right\n\n'
          '\\[ b \\]\n\n'
          '#+ATTR_ORG: :align right\n\n'
          '#+ATTR_HTML: :center t\n'
          '\\[ c \\]\n',
        ),
        {'c': 0.5},
      );
    });

    testWidgets('follows a text column that gets narrower in the same window', (
      tester,
    ) async {
      final box = layOutFormula('x = 1').box!;
      Future<void> pumpAt(double width) => tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              // As org_flutter places a block.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: AlignedFormula(
                  align: 0.5,
                  child: DrawnFormula(box, source: 'x = 1'),
                ),
              ),
            ),
          ),
        ),
      );
      for (final width in [400.0, 200.0, 300.0]) {
        await pumpAt(width);
        expect(
          tester.getRect(find.byType(DrawnFormula)).center.dx,
          closeTo(width / 2, 0.5),
          reason: '$width',
        );
      }
      // Dry layout uses only the constraints given: the formula's own size
      // without them, the room they ask for with them.
      final aligned = tester.renderObject<RenderAlignedFormula>(
        find.byType(AlignedFormula),
      );
      final own = tester.getSize(find.byType(DrawnFormula));
      expect(aligned.getDryLayout(const BoxConstraints()), own);
      expect(
        aligned.getDryLayout(const BoxConstraints(minWidth: 500)).width,
        500,
      );
      expect(tester.takeException(), isNull);
    });

    test('not a formula with text after it in its paragraph', () {
      expect(
        alignments(
          '#+ATTR_ORG: :align center\n\\[ a \\] and more text.\n\n'
          '#+ATTR_ORG: :align right\n\\[ b \\]  \n\n'
          '#+ATTR_ORG: :align center\n'
          '\\begin{equation}\nc\n\\end{equation}\n',
        ),
        {'b': 1.0, 'c': 0.5},
      );
    });

    test('not a formula inside a sentence', () {
      expect(
        alignments('#+ATTR_ORG: :align center\nText \\[ x \\] more.\n'),
        isEmpty,
      );
    });

    testWidgets('a centred and a right-aligned block in the node view', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const note =
          ':PROPERTIES:\n:ID: $_id\n:END:\n#+title: Aligned\n\n'
          '#+ATTR_ORG: :align center\n'
          '\\begin{equation}\nx = 1\n\\end{equation}\n\n'
          '#+ATTR_ORG: :align right\n'
          '\\[ y = 2 \\]\n\n'
          '\\[ z = 3 \\]\n';
      await tester.pumpWidget(
        MaterialApp(
          home: NodeScreen(
            graph: ValueNotifier(graphOf({'aligned.org': note})),
            id: _id,
            readNote: (path) async => note,
            nodeMemory: MemoryNodeMemory(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder formula(String text) => find.byWidgetPredicate(
        (widget) => widget is DrawnFormula && widget.source.contains(text),
      );
      Rect line(String text) => tester.getRect(
        find
            .ancestor(
              of: formula(text),
              matching: find.byType(SingleChildScrollView),
            )
            .first,
      );
      void check() {
        final centred = tester.getRect(formula('x = 1'));
        expect(centred.center.dx, closeTo(line('x = 1').center.dx, 1));
        final right = tester.getRect(formula('y = 2'));
        expect(right.right, closeTo(line('y = 2').right, 1));
        final left = tester.getRect(formula('z = 3'));
        expect(left.left, closeTo(line('z = 3').left, 1));
      }

      check();
      // A narrower window: the centre moves with it.
      final before = tester.getRect(formula('x = 1')).center.dx;
      tester.view.physicalSize = const Size(500, 900);
      await tester.pumpAndSettle();
      expect(tester.getRect(formula('x = 1')).center.dx, lessThan(before));
      check();
      expect(tester.takeException(), isNull);
    });
  });

  group('the callbacks', () {
    test('an inline formula is a WidgetSpan on the text baseline', () {
      final span = loadLatexInline(inlineOf(r'Text \(x^2\) here.'));
      expect(span, isA<WidgetSpan>());
      span as WidgetSpan;
      expect(span.alignment, PlaceholderAlignment.baseline);
      expect(span.baseline, TextBaseline.alphabetic);
      expect(span.child, isA<DrawnFormula>());
      expect((span.child as DrawnFormula).source, r'\(x^2\)');
    });

    test('an inline display formula is laid out in display style', () {
      // As in the AI chat, which does not turn them into blocks: a display
      // sum is taller than an inline one.
      double height(String text) =>
          ((loadLatexInline(inlineOf(text))! as WidgetSpan).child
                  as DrawnFormula)
              .box
              .height;
      expect(
        height(r'A \[\sum_{k=1}^n k\] b.'),
        greaterThan(height(r'A \(\sum_{k=1}^n k\) b.')),
      );
    });

    test('a block is drawn as a formula that sizes itself', () {
      final widget = loadLatexBlock(
        blockOf('\\begin{equation}\nx = 1 \\label{eq:x}\n\\end{equation}\n'),
      );
      expect(widget, isA<DrawnFormula>());
      expect(
        (widget! as DrawnFormula).source,
        '\\begin{equation}\nx = 1 \\label{eq:x}\n\\end{equation}',
      );
    });

    test('a formula that cannot be drawn gives null', () {
      expect(loadLatexInline(inlineOf(r'A \(\frac{1}{\) b.')), isNull);
      expect(loadLatexInline(inlineOf(r'A \(\unknowncommand{x}\) b.')), isNull);
      expect(loadLatexBlock(blockOf('$_broken\n')), isNull);
    });
  });

  group('the node view', () {
    Future<void> show(
      WidgetTester tester, {
      String text = '',
      Brightness brightness = Brightness.light,
    }) async {
      final note = text.isEmpty ? _fixture : text;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: NodeScreen(
            graph: ValueNotifier(graphOf({'note.org': note})),
            id: RegExp(r':ID: (\S+)').firstMatch(note)!.group(1)!,
            readNote: (path) async => note,
            nodeMemory: MemoryNodeMemory(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('every formula is drawn by katex, on every platform', (
      tester,
    ) async {
      await show(tester);
      // Each block that can be drawn, and the inline formula.
      expect(find.byType(DrawnFormula), findsNWidgets(_blocks - 1 + 1));
      expect(
        find.descendant(
          of: find.byType(OrgLatexBlockWidget),
          matching: find.byType(DrawnFormula),
        ),
        findsNWidgets(_blocks - 1),
      );
      expect(drawn(tester), everyElement(isA<RenderFormula>()));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.all());

    testWidgets('inline, display and environment formulas of a note', (
      tester,
    ) async {
      await show(tester, text: mu);
      // E = mc^2, a^2 + b^2 = c^2, and three blocks; the broken one is not.
      expect(find.byType(DrawnFormula), findsNWidgets(5));
      expect([
        for (final formula in tester.widgetList<DrawnFormula>(
          find.byType(DrawnFormula),
        ))
          formula.source,
      ], containsAll([r'\(E = mc^2\)', r'$a^2 + b^2 = c^2$']));
    });

    testWidgets('a formula that cannot be drawn shows its source as code', (
      tester,
    ) async {
      await show(tester, text: mu);
      final inline = styleOfText(tester, r'\(\frac{1}{\)');
      expect(inline, isNotNull);
      expect(inline!.fontFamily, monospaceTextStyle.fontFamily);
      expect(tester.takeException(), isNull);

      await show(tester);
      final block = styleOfText(tester, _broken);
      expect(block, isNotNull);
      expect(block!.fontFamily, monospaceTextStyle.fontFamily);
      // Not in KaTeX's error red.
      expect(block.color, isNot(const Color(0xFFCC0000)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a formula has the text colour and KaTeX\'s size, '
        'also in the dark theme', (tester) async {
      Future<(Color, double, double)> colourAndSize(
        Brightness brightness,
      ) async {
        await show(tester, brightness: brightness);
        final formulas = drawn(tester);
        final text = DefaultTextStyle.of(
          tester.element(find.byType(DrawnFormula).first),
        ).style;
        expect(formulas.map((formula) => formula.color).toSet(), {text.color});
        expect(
          formulas.map((formula) => formula.fontSize).toSet(),
          hasLength(1),
        );
        return (formulas.first.color, formulas.first.fontSize, text.fontSize!);
      }

      final (light, size, textSize) = await colourAndSize(Brightness.light);
      expect(size, closeTo(textSize * katexEm, 0.001));
      expect(light.computeLuminance(), lessThan(0.2));
      final (dark, _, _) = await colourAndSize(Brightness.dark);
      expect(dark.computeLuminance(), greaterThan(0.5));
    });

    testWidgets('formula and text keep their sizes together '
        'when the system text size is larger', (tester) async {
      // The system's text size, as Android and the desktops pass it to
      // the app (MediaQuery's textScaler); the app has no setting of its
      // own. org_flutter sets the scaling to 1 inside its root, so note
      // text keeps its size, and the formulas must keep theirs with it.
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      Future<(double, double, double)> sizes(double scale) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await show(tester);
        final formula = find.byWidgetPredicate(
          (widget) => widget is DrawnFormula && widget.source == r'\(a + b\)',
        );
        final text = find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().startsWith('Synthetic LaTeX for'),
        );
        expect(text, findsOneWidget);
        expect(
          MediaQuery.textScalerOf(
            tester.element(find.byType(NodeScreen)),
          ).scale(10),
          10 * scale,
        );
        return (
          drawn(tester, formula).single.fontSize,
          tester.getSize(text).height,
          tester.getSize(formula).height,
        );
      }

      final (formula1, text1, height1) = await sizes(1);
      final (formula2, text2, height2) = await sizes(2);
      expect(formula2 / text2, closeTo(formula1 / text1, 0.01));
      expect(height2 / text2, closeTo(height1 / text1, 0.01));
      // What org_flutter does today: neither grows.
      expect(text2, text1);
      expect(formula2, formula1);
    });

    testWidgets('an inline formula takes the style of the text around it', (
      tester,
    ) async {
      // A headline has the colour of its level; the formula in it too.
      await show(
        tester,
        text:
            ':PROPERTIES:\n:ID: $_id\n:END:\n#+title: Styled\n\n'
            'Body \\(y^2\\)\n\n'
            '* Level one \\(x^2\\)\n',
      );
      final heading = find.byWidgetPredicate(
        (widget) => widget is DrawnFormula && widget.source == r'\(x^2\)',
      );
      final body = find.byWidgetPredicate(
        (widget) => widget is DrawnFormula && widget.source == r'\(y^2\)',
      );
      final level = MonospaceOrgThemes.light.levelColors!.first;
      expect(drawn(tester, heading).single.color, level);
      expect(drawn(tester, body).single.color, isNot(level));
    });

    testWidgets('an inline formula sits on the text baseline', (tester) async {
      await show(tester);
      final formula = find.byWidgetPredicate(
        (widget) => widget is DrawnFormula && widget.source == r'\(a + b\)',
      );
      final render = drawn(tester, formula).single;
      final baseline = render.getDryBaseline(
        render.constraints,
        TextBaseline.alphabetic,
      )!;
      // Below the top, above the bottom: the part of a + b below the
      // baseline is small.
      expect(baseline, greaterThan(render.size.height / 2));
      expect(baseline, lessThan(render.size.height));
      // The paragraph's baseline goes through the formula's baseline.
      final paragraph = tester.renderObject<RenderParagraph>(
        find.ancestor(of: formula, matching: find.byType(RichText)).first,
      );
      final lineBaseline = paragraph.getDryBaseline(
        paragraph.constraints,
        TextBaseline.alphabetic,
      )!;
      final top = paragraph.globalToLocal(render.localToGlobal(Offset.zero)).dy;
      expect(top + baseline, closeTo(lineBaseline, 0.5));
    });

    testWidgets('a screen reader reads the formula\'s source', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester);
      expect(find.bySemanticsLabel(RegExp(r'\\frac')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r'\\\(a \+ b\\\)')), findsWidgets);
      semantics.dispose();
    });

    testWidgets('a wide inline formula scrolls sideways on a narrow screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sum = [for (var i = 1; i <= 30; i++) 'a_{$i}'].join(' + ');
      await show(
        tester,
        text:
            ':PROPERTIES:\n:ID: $_id\n:END:\n#+title: Narrow\n\n'
            'Before \\($sum\\) after.\n',
      );
      final formula = find.byType(DrawnFormula);
      final line = find.ancestor(of: formula, matching: find.byType(RichText));
      final render = drawn(tester).single;
      // The formula is wider than the line; its scroll view is not.
      expect(render.size.width, greaterThan(tester.getSize(line.first).width));
      expect(
        tester.getSize(formula).width,
        lessThanOrEqualTo(tester.getSize(line.first).width),
      );
      final scroll = find.descendant(
        of: formula,
        matching: find.byType(SingleChildScrollView),
      );
      expect(
        tester.widget<SingleChildScrollView>(scroll).scrollDirection,
        Axis.horizontal,
      );
      // Dragging shows the end of the formula.
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: scroll, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.drag(scroll, const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a formula given less room than it needs is cut to its box', (
      tester,
    ) async {
      final box = layOutFormula(r'a + b + c + d + e + f').box!;
      Future<RenderFormula> drawAt(double width) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: width,
                child: DrawnFormula(box, source: 'abc'),
              ),
            ),
          ),
        );
        return drawn(tester).single;
      }

      final narrow = await drawAt(20);
      expect(narrow.size.width, 20);
      expect(narrow, paints..clipRect(rect: Offset.zero & narrow.size));
      final wide = await drawAt(400);
      expect(wide, isNot(paints..clipRect()));
    });

    testWidgets('a wide formula scrolls sideways', (tester) async {
      await show(tester);
      final wide = find
          .byWidgetPredicate(
            (widget) =>
                widget is DrawnFormula && widget.source.contains('a_{24}'),
          )
          .first;
      await tester.ensureVisible(wide);
      await tester.pumpAndSettle();
      final scroll = find
          .ancestor(of: wide, matching: find.byType(SingleChildScrollView))
          .first;
      expect(
        tester.widget<SingleChildScrollView>(scroll).scrollDirection,
        Axis.horizontal,
      );
      expect(
        tester.getSize(wide).width,
        greaterThan(tester.getSize(scroll).width),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('an inline formula that fits takes no drags', () {
    // Each inline formula has its own sideways scroll view; one that fits
    // must not take a sideways drag from what is around it.
    const text = r'Words \(x^2\) and more words here.';

    testWidgets('a sideways swipe starting on it reaches the page', (
      tester,
    ) async {
      var swiped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              onHorizontalDragEnd: (_) => swiped++,
              child: const MonospaceOrgText(text),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(DrawnFormula), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(swiped, 1);
    });

    testWidgets('a mouse drag starting on it still selects the text', (
      tester,
    ) async {
      SelectedContent? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SelectionArea(
              onSelectionChanged: (content) => selected = content,
              child: const MonospaceOrgText(text),
            ),
          ),
        ),
      );
      final start = tester.getCenter(find.byType(DrawnFormula));
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(start + const Offset(250, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected?.plainText, contains('more words'));
    }, variant: TargetPlatformVariant.desktop());
  });

  testWidgets('formulas in the AI chat\'s text are drawn too', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MonospaceOrgText(r'Inline \(x^2\) and display \[ \sum y \].'),
        ),
      ),
    );
    expect(find.byType(DrawnFormula), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  test('the cache keeps the formulas used last', () {
    final boxes = [
      for (var i = 0; i < maxLaidOutFormulas; i++) layOutFormula('x_{$i}').box,
    ];
    expect(laidOutFormulas, maxLaidOutFormulas);
    // Used again, x_0 is now the newest; one more formula drops x_1.
    expect(layOutFormula('x_{0}').box, same(boxes[0]));
    layOutFormula('y');
    expect(laidOutFormulas, maxLaidOutFormulas);
    expect(layOutFormula('x_{0}').box, same(boxes[0]));
    expect(layOutFormula('x_{1}').box, isNot(same(boxes[1])));
    expect(laidOutFormulas, maxLaidOutFormulas);
  });

  test('laid-out formulas are kept by their text and mode', () {
    expect(
      layOutFormula(r'\frac{a}{b}').box,
      same(layOutFormula(r'\frac{a}{b}').box),
    );
    expect(
      layOutFormula(r'\frac{a}{b}', display: false).box,
      isNot(same(layOutFormula(r'\frac{a}{b}').box)),
    );
  });
}
