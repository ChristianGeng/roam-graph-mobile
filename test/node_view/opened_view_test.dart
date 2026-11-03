import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/capture/opened_file.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/node_memory.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

/// The read-only view of a file opened from outside the notes folder
/// (#243): "Add to my notes" on every page, links to notes go out.
void main() {
  const text = '#+title: Outside\n\n'
      'See [[id:hh][jump inside]] and [[id:elsewhere][a note]].\n\n'
      '* H\n:PROPERTIES:\n:ID: hh\n:END:\nText under the heading.\n';

  testWidgets('"Add to my notes" stays on its pages; other IDs go out',
      (tester) async {
    final data = viewedFile('outside.org', text);
    final added = <String>[];
    final outside = <String>[];
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => ViewSettingsHost(
        store: MemoryViewSettingsStore(
            const ViewSettings(sectionsOnOpen: SectionsOnOpen.expanded)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => NodeScreen.open(
                context,
                graph: ValueNotifier(RoamGraph.fromFiles([data])),
                id: openedFileId('outside.org'),
                readNote: (path) async => path == data.path ? text : null,
                nodeMemory: const NoNodeMemory(),
                help: true,
                shareText: (text, {subject}) async {},
                addToNotes: (pageContext) => added.add('add'),
                openOutside: (_, id) => outside.add(id),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add to my notes'), findsOneWidget);

    // A link to a note that is not in the file's own graph goes out.
    await tester.tapOnText(find.textRange.ofSubstring('a note'));
    await tester.pumpAndSettle();
    expect(outside, ['elsewhere']);
    expect(find.textContaining('There is no node'), findsNothing);

    // A heading of the file opens on its own page, with the button too.
    await tester.tapOnText(find.textRange.ofSubstring('jump inside'));
    await tester.pumpAndSettle();
    expect(find.text('H'), findsWidgets);
    await tester.tap(find.byTooltip('Add to my notes'));
    await tester.pump();
    expect(added, ['add']);
  });
}
