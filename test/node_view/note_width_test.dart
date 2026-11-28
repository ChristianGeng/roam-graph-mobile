import 'dart:io';

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/drawn_latex.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf;

// #318: a note on a phone is never wider than the screen. Synthetic text
// only (decision 14: no real notes in tests).

/// A phone, in logical pixels (dp).
const _phone = Size(412, 915);

/// The padding of the note view at the left and the right: the root
/// padding of `org_flutter`'s theme (8 on each side) for a file node.
const _padding = 16.0;

const _id = '11111111-1111-4111-8111-000000000318';

/// One long paragraph, a single line in the source.
const _paragraph =
    'The measurement loop reads every sensor once in each cycle, writes the '
    'values into the ring buffer, checks the limits of each channel and '
    'sends a short report to the logger, so that the whole loop keeps up '
    'with the clock of the device even when one of the channels is slow to '
    'answer and the buffer is almost full.';

/// The same paragraph with inline formulas.
const _paragraphWithFormulas =
    'The measurement loop reads every sensor once in each cycle, writes the '
    'values into the ring buffer, checks the limits of each channel and '
    r'sends a short report to the logger, so that a cycle of eight steps '
    r'takes $8 \times 10\text{ ms} = 80\text{ ms}$ and the whole loop runs '
    r'$8\times$ per second without falling behind the clock of the device.';

/// A table of 4 columns, about 110 characters per row.
const _table =
    '| Channel name        | Sensor type and position           '
    '| Unit and range          | Comment on calibration |\n'
    '|---------------------+------------------------------------'
    '+-------------------------+------------------------|\n'
    '| temperature-left    | thermocouple at the left inlet     '
    '| degrees Celsius, 0-400  | checked every month    |\n'
    '| pressure-main       | membrane sensor in the main line   '
    '| kilopascal, 0-1000      | checked every week     |\n';

String _note(String body) =>
    ':PROPERTIES:\n:ID: $_id\n:END:\n#+title: Wide note\n\n$body';

/// A note like the one in #318: sections under headings, a list whose
/// items have inline formulas, `*bold*` and a link in the long paragraph
/// under the third heading, and the wide table in the last section.
final _sectionsNote = _note(
  'The loggers need to cut the number of samples before they send them on. '
  'Raw readings from the front-end arrive every 10 ms; a pipeline of 31 '
  'stages cannot handle 100 readings per second of signal.\n'
  '\n'
  '* What it is\n'
  '\n'
  '*Sample stacking* (or block stacking) is the simplest form of reduction: '
  r'join $n$ consecutive samples into one wider record, then advance by $n$ '
  'samples (stride = stack size, no overlap). It is purely a reshape — no '
  'learned values, no filters.\n'
  '\n'
  '* Example\n'
  '\n'
  'For a 10 ms stride at the front-end:\n'
  '- 8 samples → 1 stacked record\n'
  r'- Each step covers $8 \times 10\text{ ms} = 80\text{ ms}$ of time' '\n'
  r'- The length is reduced by $8\times$' '\n'
  '\n'
  '* Why stacking instead of filters?\n'
  '\n'
  'Filter reduction (for example two low-pass filters with stride 2) is '
  'common in logger front-ends and mixes information across neighbouring '
  'samples. In a *streaming* setting with a sample cache (chunked reading '
  'with a carry-over buffer, as in '
  '[[id:11111111-1111-4111-8111-000000000999][logger-three]]), those '
  'filters can create seams: the filter kernel straddles a chunk boundary '
  'and leaks information from one chunk into another, where the cache '
  'logic does not expect it.\n'
  '\n'
  '* Trade-offs\n'
  '\n'
  '- Simplicity: no learned values, easy to build, safe for the cache.\n'
  '- Fixed reduction factor: the factor must divide the record step.\n'
  '\n'
  '* In practice\n'
  '\n'
  '$_table'
  '\n'
  'All three reach the same 80 ms record step, but the plain pipeline with '
  'stacking cut memory use by 2.8× and reading time by 2.2× on 64× test '
  'boards.\n',
);

/// Loads Roboto (Material's font on Android) and the KaTeX fonts, so that
/// text and formulas are measured with the fonts of the phone, not the
/// square test font.
Future<void> _loadRealFonts(WidgetTester tester) => tester.runAsync(() async {
      // flutter_tester is in <flutter>/bin/cache/artifacts/engine/<host>/.
      final cache = File(Platform.resolvedExecutable).parent.parent.parent;
      final roboto = FontLoader('Roboto');
      for (final style in ['Regular', 'Medium', 'Bold', 'Italic']) {
        final file = File('${cache.path}/material_fonts/Roboto-$style.ttf');
        roboto.addFont(file.readAsBytes().then(ByteData.sublistView));
      }
      await roboto.load();
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final asset in manifest.listAssets()) {
        final name = RegExp(r'^packages/katex/fonts/(KaTeX_[\w-]+)\.ttf$')
            .firstMatch(asset)
            ?.group(1);
        if (name == null) continue;
        await (FontLoader('packages/katex/$name')
              ..addFont(rootBundle.load(asset)))
            .load();
      }
    });

/// [note] in the node view on a phone, with "Join lines of a paragraph"
/// on.
Future<void> _show(
  WidgetTester tester,
  String note, {
  SectionsOnOpen sections = SectionsOnOpen.collapsed,
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ViewSettingsHost(
        store: MemoryViewSettingsStore(
          ViewSettings(joinLines: true, sectionsOnOpen: sections),
        ),
        child: child!,
      ),
      home: NodeScreen(
        graph: ValueNotifier(graphOf({'wide.org': note})),
        id: _id,
        readNote: (path) async => note,
        nodeMemory: MemoryNodeMemory(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Whether [element] is inside a widget that may scroll sideways on its
/// own: a table, or an inline formula's own scroll view.
bool _inOwnScrollView(Element element) {
  var inside = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is OrgTableWidget || widget is DrawnFormula) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

/// Checks that the note fits the screen: no paragraph of text is wider
/// than the screen minus the view's padding, and nothing in the note
/// scrolls sideways but the table and a formula's own scroll view.
void _expectFits(WidgetTester tester) {
  final note = find.byType(OrgRootWidget);
  expect(note, findsOneWidget);
  final width = _phone.width - _padding;
  final paragraphs = find
      .descendant(of: note, matching: find.byType(RichText))
      .evaluate()
      .where((element) => !_inOwnScrollView(element));
  expect(paragraphs, isNotEmpty);
  for (final element in paragraphs) {
    final paragraph = element.renderObject! as RenderParagraph;
    // The laid-out text, which is wider than the box when a line does not
    // fit, and where it ends on the screen.
    final wide = paragraph.textSize.width > paragraph.size.width
        ? paragraph.textSize.width
        : paragraph.size.width;
    final right = paragraph.localToGlobal(Offset.zero).dx + wide;
    expect(
      wide,
      lessThanOrEqualTo(width + 0.01),
      reason: 'a paragraph is $wide wide, more than $width: '
          '"${paragraph.text.toPlainText()}"',
    );
    expect(
      right,
      lessThanOrEqualTo(_phone.width - _padding / 2 + 0.01),
      reason: 'a paragraph ends at $right, after the padding',
    );
  }
  for (final element in find
      .descendant(of: note, matching: find.byType(Scrollable))
      .evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    if (state.axisDirection != AxisDirection.right &&
        state.axisDirection != AxisDirection.left) {
      continue;
    }
    if (_inOwnScrollView(element)) continue;
    expect(
      state.position.maxScrollExtent,
      0,
      reason: 'the note scrolls sideways by '
          '${state.position.maxScrollExtent}',
    );
  }
  // The screen itself does not scroll sideways either.
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    if (state.axisDirection != AxisDirection.right &&
        state.axisDirection != AxisDirection.left) {
      continue;
    }
    if (_inOwnScrollView(element)) continue;
    expect(state.position.maxScrollExtent, 0);
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(forgetLaidOutFormulas);
  tearDown(forgetLaidOutFormulas);

  group('a note on a phone is as wide as the screen (#318)', () {
    testWidgets('(a) a long paragraph alone', (tester) async {
      await _show(tester, _note('$_paragraph\n'));
      _expectFits(tester);
    });

    testWidgets('(b) a long paragraph and a wide table', (tester) async {
      await _show(tester, _note('$_paragraph\n\n$_table'));
      // The table is wider than the screen and scrolls on its own.
      final table = find.descendant(
        of: find.byType(OrgTableWidget),
        matching: find.byType(Scrollable),
      );
      expect(
        tester.state<ScrollableState>(table.first).position.maxScrollExtent,
        greaterThan(0),
      );
      _expectFits(tester);
    });

    testWidgets('(c) a long paragraph with inline formulas and a wide table',
        (tester) async {
      await _show(tester, _note('$_paragraphWithFormulas\n\n$_table'));
      expect(find.byType(DrawnFormula), findsNWidgets(2));
      _expectFits(tester);
    });
    for (final folded in [false, true]) {
      testWidgets(
          '(d) sections, formulas in a list, bold and a link, and the table '
          'in the last section ${folded ? 'folded' : 'unfolded'}, with the '
          'real fonts', (tester) async {
        await _loadRealFonts(tester);
        await _show(tester, _sectionsNote, sections: SectionsOnOpen.expanded);
        if (folded) {
          await tester.tap(find.textContaining('In practice'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(OrgTableWidget), findsNWidgets(folded ? 0 : 1));
        expect(find.byType(DrawnFormula), findsNWidgets(4));
        _expectFits(tester);
      });
    }
  });
}
