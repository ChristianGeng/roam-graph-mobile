import 'package:flutter/rendering.dart' show RenderParagraph;
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

/// [note] in the node view on a phone, with "Join lines of a paragraph"
/// on.
Future<void> _show(WidgetTester tester, String note) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ViewSettingsHost(
        store: MemoryViewSettingsStore(const ViewSettings(joinLines: true)),
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
  });
}
