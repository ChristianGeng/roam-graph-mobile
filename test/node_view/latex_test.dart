import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_tex_js/flutter_tex_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/latex.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf;

/// A synthetic PNG, for the formulas the mock renders.
final png = File('test/fixtures/images/red-40x20.png').readAsBytesSync();

/// The sample note with inline, display and broken formulas and an
/// `equation` environment (decision 14: synthetic).
final mu = File('test/fixtures/roam/20240112120000-mu.org').readAsStringSync();

List<T> nodesOf<T extends OrgNode>(OrgDocument document) {
  final found = <T>[];
  document.visit<T>((node) {
    found.add(node);
    return true;
  });
  return found;
}

/// [latex] as flutter_tex_js sends it to KaTeX: in a JavaScript string,
/// with backslashes and line breaks escaped.
String katexText(String latex) =>
    latex.replaceAll(r'\', r'\\').replaceAll('\n', r'\n');

void main() {
  test('display formulas become LaTeX blocks, inline ones stay', () {
    final document = withDisplayFormulas(OrgDocument.parse(mu));
    expect(
        [
          for (final block in nodesOf<OrgLatexBlock>(document))
            (block.begin, block.content.trim(), block.end),
        ],
        [
          (r'\[', r'\int_0^1 x^2 \, dx = \frac{1}{3}', r'\]'),
          (r'$$', r'\sum_{k=1}^{n} k = \frac{n(n+1)}{2}', r'$$'),
          (r'\begin{equation}', r'\nabla \cdot \mathbf{B} = 0',
              r'\end{equation}'),
        ]);
    expect(
        [
          for (final inline in nodesOf<OrgLatexInline>(document))
            inline.leadingDecoration,
        ],
        [r'\(', r'$', r'\(']);
  });

  test('a document without display formulas is left as it is', () {
    final document = OrgDocument.parse(r'Only \(x\) here.');
    expect(withDisplayFormulas(document), same(document));
  });

  /// The render requests to flutter_tex_js's channel, which runs KaTeX in
  /// a WebView on the device. Widget tests have no WebView: the mock
  /// answers like KaTeX, with an image, or an error for the broken formula.
  late List<Map<Object?, Object?>> renders;

  setUp(() {
    renders = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tex_js'),
            (call) async {
      if (call.method != 'render') return null;
      final arguments = call.arguments as Map<Object?, Object?>;
      renders.add(arguments);
      if (arguments['text'] == katexText(r'\frac{1}{')) {
        throw PlatformException(code: 'katex', message: 'Expected group');
      }
      return png;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tex_js'), null);
  });

  Future<void> show(WidgetTester tester,
      {Brightness brightness = Brightness.light}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: NodeScreen(
        graph: ValueNotifier(graphOf({'mu.org': mu})),
        id: '11111111-1111-4111-8111-000000000013',
        readNote: (path) async => mu,
        nodeMemory: MemoryNodeMemory(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('display formulas are rendered in display mode',
      (tester) async {
    await show(tester);
    expect(find.byType(OrgLatexBlockWidget), findsNWidgets(3));
    expect(find.byType(OrgLatexInlineWidget), findsNWidgets(3));
    expect(
        {
          for (final render in renders)
            render['text']: render['displayMode'],
        },
        {
          katexText('E = mc^2'): false,
          katexText('a^2 + b^2 = c^2'): false,
          katexText(r' \int_0^1 x^2 \, dx = \frac{1}{3} '): true,
          katexText(r'\sum_{k=1}^{n} k = \frac{n(n+1)}{2}'): true,
          katexText('\\begin{equation}\n\\nabla \\cdot \\mathbf{B} = 0\n'
              '\\end{equation}'): true,
          katexText(r'\frac{1}{'): false,
        });
  });

  testWidgets('a formula KaTeX cannot render shows its source',
      (tester) async {
    await show(tester);
    final text = [
      for (final widget in tester.widgetList<Text>(find.byType(Text)))
        widget.data ?? '',
    ].join('\n');
    expect(text, contains(r'\(\frac{1}{\)'));
    // The others are images.
    expect(
        find.descendant(
            of: find.byType(TexImage), matching: find.byType(Image)),
        findsNWidgets(5));
  });

  testWidgets('formulas take the colour of the text, also in dark mode',
      (tester) async {
    Future<Set<Object?>> colours(Brightness brightness) async {
      renders.clear();
      await show(tester, brightness: brightness);
      // The colour each formula was rendered with last: the app animates
      // from one theme to the other, rendering them again on the way.
      final last = {
        for (final render in renders) render['text']: render['color'],
      };
      expect(last, hasLength(6));
      return last.values.toSet();
    }

    final light = await colours(Brightness.light);
    final dark = await colours(Brightness.dark);
    expect(light, hasLength(1));
    expect(dark, hasLength(1));
    expect(dark, isNot(light));
    // The text colour, as flutter_tex_js passes it to KaTeX: dark on light,
    // light on dark.
    int red(Object? css) =>
        int.parse(RegExp(r'^rgb\((\d+)').firstMatch(css! as String)!.group(1)!);
    expect(red(light.single), lessThan(100));
    expect(red(dark.single), greaterThan(150));
  });
}
