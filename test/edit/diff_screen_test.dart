import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/edit/diff_screen.dart';

Future<void> show(WidgetTester tester, String before, String after) async {
  await tester.pumpWidget(MaterialApp(
    home: DiffScreen(title: 'T', before: before, after: after),
  ));
  await tester.pumpAndSettle();
}

bool saveEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed !=
    null;

void main() {
  testWidgets('the same text: nothing to save', (tester) async {
    await show(tester, 'a\n', 'a\n');
    expect(find.text('No change.'), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('only the final newline or line endings change: still saved',
      (tester) async {
    await show(tester, 'a\n', 'a');
    expect(find.text('Only the line endings or the newline at the end change.'),
        findsOneWidget);
    expect(saveEnabled(tester), isTrue);
    await show(tester, 'a\r\nb\r\n', 'a\nb\n');
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('too many changes: a summary, and it can still be saved',
      (tester) async {
    final a = [for (var i = 0; i < 1500; i++) 'a$i'].join('\n');
    final b = [for (var i = 0; i < 1500; i++) 'b$i'].join('\n');
    await show(tester, '$a\n', '$b\n');
    expect(find.textContaining('Too many changes to show line by line'),
        findsOneWidget);
    expect(saveEnabled(tester), isTrue);
  });
}
