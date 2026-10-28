import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/edit/tag_field.dart';

import '../ai/ai_visibility_test.dart' show graphOf;
import '../widget_test.dart';
import 'add_link_test.dart' show openNode;

/// Synthetic notes: gmbh in three notes (once only on a heading node),
/// GmbH in one, work in two, x in one.
final graph = graphOf({
  'a.org': ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\n#+filetags: :gmbh:work:\n'
      '* Sub\n:PROPERTIES:\n:ID: a1\n:END:\n',
  'b.org': ':PROPERTIES:\n:ID: b\n:END:\n#+title: B\n#+filetags: :gmbh:\n',
  'c.org': ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\n'
      '* Firm :gmbh:\n:PROPERTIES:\n:ID: c1\n:END:\n',
  'd.org': ':PROPERTIES:\n:ID: d\n:END:\n#+title: D\n#+filetags: :GmbH:work:x:\n',
});

/// The labels of the suggestions, in their order.
List<String> suggestions(WidgetTester tester) => [
      for (final chip in tester.widgetList<ActionChip>(find.byType(ActionChip)))
        (chip.label as Text).data!,
    ];

Future<TagFieldController> pumpField(WidgetTester tester,
    [List<String> tags = const []]) async {
  final controller = TagFieldController(tags);
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TagField(
        key: const ValueKey('tags'),
        controller: controller,
        known: tagCounts(graph),
      ),
    ),
  ));
  return controller;
}

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('tags')), text);
  await tester.pump();
}

void main() {
  group('the tag field (#140)', () {
    test('the graph\'s tags, most used first, counted by note', () {
      expect(tagCounts(graph), [
        (tag: 'gmbh', notes: 3),
        (tag: 'work', notes: 2),
        (tag: 'GmbH', notes: 1),
        (tag: 'x', notes: 1),
      ]);
      expect(tagCounts(null), isEmpty);
    });

    testWidgets('the chosen tags are chips; the x removes one',
        (tester) async {
      final controller = await pumpField(tester, ['work', 'idea']);
      expect(find.widgetWithText(InputChip, 'work'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'idea'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove work'));
      await tester.pump();
      expect(find.widgetWithText(InputChip, 'work'), findsNothing);
      expect(controller.tags, ['idea']);
    });

    testWidgets('the suggestions are the graph\'s tags without the chosen',
        (tester) async {
      final controller = await pumpField(tester, ['work']);
      expect(suggestions(tester), ['gmbh (3)', 'GmbH (1)', 'x (1)']);
      await tester.tap(find.text('GmbH (1)'));
      await tester.pump();
      expect(controller.tags, ['work', 'GmbH']);
      expect(suggestions(tester), ['gmbh (3)', 'x (1)']);
    });

    testWidgets('typing filters, ignoring case', (tester) async {
      await pumpField(tester);
      await type(tester, 'GM');
      // GM is no tag as written, so it is also offered as new.
      expect(suggestions(tester), ['New tag: GM', 'gmbh (3)', 'GmbH (1)']);
      await type(tester, 'or');
      expect(suggestions(tester), ['New tag: or', 'work (2)']);
    });

    testWidgets('a text that is no tag is marked as new; tags are compared '
        'as written', (tester) async {
      final controller = await pumpField(tester);
      await type(tester, 'gmhb');
      expect(suggestions(tester), ['New tag: gmhb']);
      // GmbH exists as written: no "New tag", and gmbh is offered too.
      await type(tester, 'GmbH');
      expect(suggestions(tester), ['gmbh (3)', 'GmbH (1)']);
      await type(tester, 'Gmbh');
      expect(suggestions(tester), ['New tag: Gmbh', 'gmbh (3)', 'GmbH (1)']);
      await tester.tap(find.text('New tag: Gmbh'));
      await tester.pump();
      expect(controller.chosen, ['Gmbh']);
      expect(controller.text.text, isEmpty);
    });

    testWidgets('space, comma, colon and Enter add the typed text',
        (tester) async {
      final controller = await pumpField(tester);
      await type(tester, 'one two,three:four');
      expect(controller.chosen, ['one', 'two', 'three']);
      expect(controller.text.text, 'four');
      // Typed but not added yet: saved with the others.
      expect(controller.tags, ['one', 'two', 'three', 'four']);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(controller.chosen, ['one', 'two', 'three', 'four']);
      expect(controller.text.text, isEmpty);
      // A tag chosen already is not added twice.
      await type(tester, 'two ');
      expect(controller.chosen, ['one', 'two', 'three', 'four']);
    });

    testWidgets('a character Org does not allow in a tag is refused',
        (tester) async {
      final controller = await pumpField(tester);
      await type(tester, 'big-deal.');
      expect(controller.text.text, 'bigdeal');
      expect(
          find.text('"-" "." cannot be in a tag: only letters, digits and '
              '_@#% can.'),
          findsOneWidget);
      await type(tester, 'bigdeal_2@ü');
      expect(find.textContaining('cannot be in a tag'), findsNothing);
      expect(controller.text.text, 'bigdeal_2@ü');
    });

    testWidgets('a long list shows the first 20, then all', (tester) async {
      final controller = TagFieldController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TagField(
              controller: controller,
              known: [for (var i = 0; i < 25; i++) (tag: 't$i', notes: 1)],
            ),
          ),
        ),
      ));
      expect(suggestions(tester), hasLength(20));
      await tester.tap(find.text('All 25 tags'));
      await tester.pump();
      expect(suggestions(tester), hasLength(25));
    });
  });

  group('the screens save the tags chosen with the field (#140)', () {
    testWidgets('"Title, tags and aliases"', (tester) async {
      final access = withNotes(saved: writableOrg);
      await openNode(tester, access, 'b');
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title, tags and aliases'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'x'), findsOneWidget);
      // x is chosen, so it is not offered.
      expect(find.text('x (1)'), findsNothing);
      await tester.tap(find.byTooltip('Remove x'));
      await tester.pump();
      expect(find.text('x (1)'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('meta-tags')), 'y ');
      await tester.pump();
      await tester.tap(find.text('x (1)'));
      await tester.pump();
      await tester.tap(find.byTooltip('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(access.texts['roam/b.org'], contains('\n#+filetags: :y:x:\n'));
    });

    testWidgets('"New node"', (tester) async {
      final access = withNotes(saved: writableOrg, picked: writableOrg);
      await start(tester, access);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New node'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('capture-title')), 'Tagged');
      await tester.pump();
      await tester.tap(find.text('x (1)'));
      await tester.pump();
      await tester.enterText(
          find.byKey(const ValueKey('capture-tags')), 'new_one');
      await tester.pump();
      expect(find.text('New tag: new_one'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final (_, name) = access.created.single;
      expect(access.texts['roam/$name'],
          contains('#+title: Tagged\n#+filetags: :x:new_one:'));
    });
  });
}
