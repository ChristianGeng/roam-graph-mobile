import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph/graph_scope_test.dart' show graphOf;
import 'graph_screen_test.dart' show graph, phoneScreen, show, tapMiddle;

const tabletLandscape = Size(1280, 800);
const tabletPortrait = Size(800, 1280);
const phone = phoneScreen;

Finder pane = find.byKey(const ValueKey('node-pane'));

/// The title of the node in the side pane.
Finder paneTitle(String text) => find.descendant(
    of: find.descendant(of: pane, matching: find.byType(AppBar)),
    matching: find.text(text));

void main() {
  test('two panes only on a tablet in landscape', () {
    expect(isTwoPane(tabletLandscape), isTrue);
    expect(isTwoPane(tabletPortrait), isFalse);
    expect(isTwoPane(phone), isFalse);
    // A large phone held sideways is wide, but no tablet.
    expect(isTwoPane(const Size(915, 412)), isFalse);
  });

  group('tablet in landscape', () {
    testWidgets('graph and node side by side, starting on the centre node',
        (tester) async {
      await show(tester, remembered: 'hub', screen: tabletLandscape);

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(paneTitle('HUB'), findsOneWidget);
      // No quick switch: the node view is already on screen.
      expect(find.byTooltip('Open node'), findsNothing);
    });

    testWidgets('links open in the pane, which has its own Back',
        (tester) async {
      final memory = await show(tester, remembered: 'hub', screen: tabletLandscape);

      // f links to hub: a backlink in the pane.
      await tester.tap(find.descendant(of: pane, matching: find.text('F')));
      await tester.pumpAndSettle();
      expect(paneTitle('F'), findsOneWidget);
      expect(memory.id, 'f');
      // Still one page: the graph is next to it.
      expect(find.byType(NodeScreen), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);

      await tester.tap(find.descendant(of: pane, matching: find.byTooltip('Back')));
      await tester.pumpAndSettle();
      expect(paneTitle('HUB'), findsOneWidget);
      expect(find.descendant(of: pane, matching: find.byTooltip('Back')),
          findsNothing);
    });

    testWidgets('a tap in the graph updates the pane', (tester) async {
      await show(tester, remembered: 'hub', screen: tabletLandscape);
      await tester.tap(find.descendant(of: pane, matching: find.text('F')));
      await tester.pumpAndSettle();
      expect(paneTitle('F'), findsOneWidget);

      // The graph did not move: hub is still in its middle.
      await tapMiddle(tester);
      expect(paneTitle('HUB'), findsOneWidget);
      expect(find.byType(NodeScreen), findsOneWidget);
    });

    testWidgets('"Show in graph" in the pane centres the graph',
        (tester) async {
      await show(tester, remembered: 'hub', screen: tabletLandscape);
      await tester.tap(find.descendant(of: pane, matching: find.text('F')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.descendant(of: pane, matching: find.byTooltip('Show in graph')));
      await tester.pumpAndSettle();

      // Now f is in the middle of the graph.
      await tester.tap(find.descendant(of: pane, matching: find.byTooltip('Back')));
      await tester.pumpAndSettle();
      expect(paneTitle('HUB'), findsOneWidget);
      await tapMiddle(tester);
      expect(paneTitle('F'), findsOneWidget);
    });

    testWidgets('a search result opens in the pane', (tester) async {
      await show(tester, remembered: 'hub', screen: tabletLandscape);
      // The graph's search button, not the pane's.
      await tester.tap(find.byTooltip('Search').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'lonely');
      await tester.pump();
      await tester.tap(find.text('LONELY'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(paneTitle('LONELY'), findsOneWidget);
      expect(find.byType(NodeScreen), findsOneWidget);
    });
  });

  group('one screen at a time', () {
    for (final (name, size) in [
      ('phone', phone),
      ('tablet in portrait', tabletPortrait),
    ]) {
      testWidgets('$name: the graph alone, with a quick switch',
          (tester) async {
        await show(tester, remembered: 'hub', screen: size);
        expect(pane, findsNothing);

        await tester.tap(find.byTooltip('Open node'));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(
            find.descendant(
                of: find.byType(AppBar), matching: find.text('HUB')),
            findsOneWidget);

        await tester.tap(find.byTooltip('Show in graph'));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
      });
    }

    testWidgets('turning the tablet switches the layout', (tester) async {
      await show(tester, remembered: 'hub', screen: tabletLandscape);
      expect(pane, findsOneWidget);

      tester.view.physicalSize = tabletPortrait;
      await tester.pumpAndSettle();
      expect(pane, findsNothing);
      expect(find.byTooltip('Open node'), findsOneWidget);
      // Centred again for the new size: hub is in the middle.
      await tapMiddle(tester);
      expect(
          find.descendant(of: find.byType(AppBar), matching: find.text('HUB')),
          findsOneWidget);
    });
  });

  group('the pane follows the selected node', () {
    testWidgets('a node deleted from the notes leaves the pane',
        (tester) async {
      final notifier = ValueNotifier(graph);
      await show(tester,
          notifier: notifier, remembered: 'hub', screen: tabletLandscape);
      await tester.tap(find.descendant(of: pane, matching: find.text('F')));
      await tester.pumpAndSettle();
      expect(paneTitle('F'), findsOneWidget);

      // Syncthing deleted f.
      notifier.value = graphOf(
        ['hub', 'a', 'b', 'c', 'd', 'e', 'lonely'],
        ['hub>a', 'hub>b', 'hub>c', 'hub>e', 'a>b', 'c>d'],
      );
      await tester.pumpAndSettle();
      expect(paneTitle('HUB'), findsOneWidget);
      expect(find.descendant(of: pane, matching: find.byTooltip('Back')),
          findsNothing);
    });

    testWidgets('after turning the tablet, the pane shows the newer choice',
        (tester) async {
      await show(tester, remembered: 'hub', screen: tabletLandscape);
      await tester.tap(find.descendant(of: pane, matching: find.text('F')));
      await tester.pumpAndSettle();

      // Upright: hub chosen by search, which opens its page.
      tester.view.physicalSize = tabletPortrait;
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hub');
      await tester.pump();
      await tester.tap(find.text('HUB'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      tester.view.physicalSize = tabletLandscape;
      await tester.pumpAndSettle();
      expect(paneTitle('HUB'), findsOneWidget);
      // Back returns to f, chosen before.
      await tester.tap(find.descendant(of: pane, matching: find.byTooltip('Back')));
      await tester.pumpAndSettle();
      expect(paneTitle('F'), findsOneWidget);
    });

    testWidgets('a search result outside the drawn part is drawn around',
        (tester) async {
      await show(tester, remembered: 'hub', screen: tabletLandscape);
      await tester.tap(find.byTooltip('Show'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Neighbourhood: 1 step'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'lonely');
      await tester.pump();
      await tester.tap(find.text('LONELY'));
      await tester.pumpAndSettle();

      expect(paneTitle('LONELY'), findsOneWidget);
      // The graph's bar names the node the neighbourhood is around.
      expect(
          find.descendant(
              of: find.byType(AppBar).first, matching: find.text('LONELY')),
          findsOneWidget);
    });
  });

  testWidgets('the keyboard does not move the graph', (tester) async {
    await show(tester, remembered: 'hub');
    await tester.drag(find.byType(InteractiveViewer), const Offset(150, 300));
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();

    // Not centred again: the middle is still empty after the drag.
    await tapMiddle(tester);
    expect(find.byType(NodeScreen), findsNothing);
  });
}
