import 'package:material_ui/material_ui.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/capture/share_inbox.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/scripts.dart' show ScriptMode;
import 'package:roam_graph_mobile/node_view/web_links.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../graph/graph_scope_test.dart' show fixtureGraph;
import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;

/// A: a file node that links to B, to its own heading H, to a missing
/// note and to a web page. B: a file with a heading node P, and a link to
/// A under a heading that is no node. C: links to A at the top.
const notes = {
  'a.org': ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\n'
      'Some text of A, [[id:b][to Bee]] and [[id:h][the heading]].\n'
      'Also [[id:gone][a lost note]] and [[https://example.com][the web]].\n'
      '* H\n:PROPERTIES:\n:ID: h\n:END:\nText under H.\n',
  'b.org': ':PROPERTIES:\n:ID: b\n:END:\n#+title: B\nTop text of B.\n'
      'Jump to [[*Part][the part]] or [[*Other][the other]].\n'
      '* Part\n:PROPERTIES:\n:ID: p\n:END:\nPart text.\n'
      '** Deeper\nDeeper text.\n'
      '* Other\nOther text, [[id:a][back to A]].\n',
  'c.org': ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\nSee [[id:a][A]].\n',
};

RoamGraph graphOf(Map<String, String> texts) => RoamGraph.fromFiles([
      for (final MapEntry(:key, :value) in texts.entries)
        parseRoamFile(key, value),
    ]);

/// Text inside the rendered Org, which is rich text.
Finder orgText(String text) => find.textContaining(text, findRichText: true);

Future<MemoryNodeMemory> open(
  WidgetTester tester,
  String id, {
  ValueNotifier<RoamGraph>? graph,
  Map<String, String> texts = notes,
  void Function(BuildContext, String)? onShowInGraph,
  NoteOpener? openInOrgro,
  TextSharer? shareText,
  UrlOpener? openUrl,
  // Expanded, so the tests below see the text under headings; the
  // folding has its own tests.
  SectionsOnOpen sections = SectionsOnOpen.expanded,
  ScriptMode scripts = ScriptMode.braces,
}) async {
  final memory = MemoryNodeMemory();
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => ViewSettingsHost(
      store: MemoryViewSettingsStore(ViewSettings(sectionsOnOpen: sections, scripts: scripts)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => NodeScreen.open(
              context,
              graph: graph ?? ValueNotifier(graphOf(notes)),
              id: id,
              readNote: (path) async => texts[path],
              nodeMemory: memory,
              onShowInGraph: onShowInGraph,
              openInOrgro: openInOrgro,
              shareText: shareText ?? (text, {subject}) async {},
              openUrl: openUrl ?? (uri) async => true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return memory;
}

/// Taps "Share with AI" in the node view's AI menu.
Future<void> shareNodeWithAi(WidgetTester tester) async {
  await tester.tap(find.byTooltip('AI').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Share with AI').last);
}

/// The title in the app bar.
Finder title(String text) =>
    find.descendant(of: find.byType(AppBar), matching: find.text(text));

void main() {
  testWidgets('a file node shows the whole file, and is remembered',
      (tester) async {
    final memory = await open(tester, 'a');

    expect(title('A'), findsOneWidget);
    expect(orgText('Some text of A'), findsOneWidget);
    expect(orgText('Text under H.'), findsOneWidget);
    expect(memory.id, 'a');
  });

  testWidgets('a heading node shows its heading and subtree only',
      (tester) async {
    await open(tester, 'p');

    expect(title('Part'), findsOneWidget);
    expect(orgText('Part text.'), findsOneWidget);
    expect(orgText('Deeper text.'), findsOneWidget);
    expect(orgText('Top text of B.'), findsNothing);
    expect(orgText('Other text'), findsNothing);
  });

  testWidgets('an id: link opens its node, and Back returns', (tester) async {
    final memory = await open(tester, 'a');

    await tester.tapOnText(find.textRange.ofSubstring('to Bee'));
    await tester.pumpAndSettle();
    expect(title('B'), findsOneWidget);
    expect(orgText('Top text of B.'), findsOneWidget);
    expect(memory.id, 'b');

    // And on from B, back to A through its link under Other.
    await tester.tapOnText(find.textRange.ofSubstring('back to A'));
    await tester.pumpAndSettle();
    expect(title('A'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(title('B'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(title('A'), findsOneWidget);
  });

  testWidgets('a link to a heading of the same file opens that node',
      (tester) async {
    await open(tester, 'a');

    await tester.tapOnText(find.textRange.ofSubstring('the heading'));
    await tester.pumpAndSettle();
    expect(title('H'), findsOneWidget);
    expect(orgText('Text under H.'), findsOneWidget);
    expect(orgText('Some text of A'), findsNothing);
  });

  testWidgets('a [[*Heading]] link opens the heading if it is a node, '
      'and goes to it in the note if it is not (#211)', (tester) async {
    await open(tester, 'b');

    await tester.tapOnText(find.textRange.ofSubstring('the other'));
    await tester.pumpAndSettle();
    expect(find.text('This heading is no node, so the app cannot open it.'),
        findsNothing);
    expect(title('B'), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('the part'));
    await tester.pumpAndSettle();
    expect(title('Part'), findsOneWidget);
  });

  testWidgets('a link to a missing note says so; a web link opens (#108)',
      (tester) async {
    final opened = <Uri>[];
    await open(tester, 'a', openUrl: (uri) async {
      opened.add(uri);
      return true;
    });

    await tester.tapOnText(find.textRange.ofSubstring('a lost note'));
    await tester.pump();
    expect(find.text('There is no node with the ID gone.'), findsOneWidget);
    expect(title('A'), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('the web'));
    await tester.pump();
    expect(opened, [Uri.parse('https://example.com')]);
    expect(find.text('Opening https://example.com'), findsOneWidget);
    // The address can be copied, once the snack bar is in.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SnackBarAction, 'Copy'));
    await tester.pumpAndSettle();
    expect(copied, 'https://example.com');
    expect(title('A'), findsOneWidget);

    // Without pressing Copy, the action must not keep the message open.
    await tester.tapOnText(find.textRange.ofSubstring('the web'));
    await tester.pumpAndSettle();
    final message = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(message.duration, externalLinkSnackBarDuration);
    expect(message.persist, isFalse);
    expect(find.widgetWithText(SnackBarAction, 'Copy'), findsOneWidget);
    await tester.pump(externalLinkSnackBarDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('mail, phone and plain web links open; file links do not',
      (tester) async {
    const texts = {
      'w.org': ':PROPERTIES:\n:ID: w\n:END:\n#+title: W\n'
          'Write [[mailto:a@example.org][mail]], call [[tel:+4930123][phone]].\n'
          'Plain https://example.org/page here.\n'
          'A [[file:other.org][file link]] and [[ftp://x.org/f][ftp]].\n',
    };
    final opened = <String>[];
    var canOpen = true;
    await open(tester, 'w',
        graph: ValueNotifier(graphOf(texts)),
        texts: texts,
        openUrl: (uri) async {
          opened.add(uri.toString());
          return canOpen;
        });
    await tester.tapOnText(find.textRange.ofSubstring('mail'));
    await tester.pump();
    await tester.tapOnText(find.textRange.ofSubstring('phone'));
    await tester.pump();
    // A plain link is drawn with zero-width spaces between its letters,
    // so it can wrap anywhere.
    await tester.tapOnText(find.textRange
        .ofSubstring('example.org/page'.split('').join('\u200b')));
    await tester.pump();
    expect(opened, [
      'mailto:a@example.org',
      'tel:+4930123',
      'https://example.org/page',
    ]);
    await tester.tapOnText(find.textRange.ofSubstring('file link'));
    await tester.pump();
    expect(
        find.text('This app opens id:, web, mail and phone links, not '
            '"file:other.org".'),
        findsOneWidget);
    await tester.tapOnText(find.textRange.ofSubstring('ftp'));
    await tester.pump();
    expect(opened, hasLength(3));
    // No app for it. The message above names mail links too: away with it.
    canOpen = false;
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).last))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tapOnText(find.textRange.ofSubstring('mail'));
    await tester.pump();
    expect(find.text('No app can open mailto:a@example.org'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SnackBarAction, 'Copy'), findsOneWidget);
    await tester.pump(externalLinkSnackBarDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the backlinks, as org-roam lists them, open their nodes',
      (tester) async {
    await open(tester, 'a');

    expect(find.text('Backlinks: 2'), findsOneWidget);
    // Sorted by title; B's link is under the heading Other.
    expect(
      tester.widget<ListTile>(find.byKey(const ValueKey('backlink-0'))).title,
      isA<Text>().having((t) => t.data, 'title', 'B'),
    );
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Top'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('backlink-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backlink-1')));
    await tester.pumpAndSettle();
    expect(title('C'), findsOneWidget);
    expect(find.text('No backlinks'), findsOneWidget);
  });

  testWidgets('"Show in graph" hands over the node', (tester) async {
    String? shown;
    await open(tester, 'b', onShowInGraph: (_, id) => shown = id);

    await tester.tap(find.byTooltip('Show in graph'));
    expect(shown, 'b');
  });

  testWidgets('without the graph view, there is no "Show in graph"',
      (tester) async {
    await open(tester, 'b');
    expect(find.byTooltip('Show in graph'), findsNothing);
  });

  group('"Open in Orgro"', () {
    testWidgets('a file node opens its file, without a message',
        (tester) async {
      final opened = <String>[];
      await open(tester, 'b', openInOrgro: (path, {line = 1}) async {
        opened.add(path);
        return OpenResult.opened;
      });
      await tester.tap(find.byTooltip('Open in Orgro'));
      await tester.pump();
      expect(opened, ['b.org']);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a heading node opens its file at the top, and says so',
        (tester) async {
      final opened = <String>[];
      await open(tester, 'p', openInOrgro: (path, {line = 1}) async {
        opened.add(path);
        return OpenResult.opened;
      });
      await tester.tap(find.byTooltip('Open in Orgro'));
      await tester.pump();
      expect(opened, ['b.org']);
      expect(
          find.text('Orgro opens b.org at the top; '
              'it cannot jump to the heading.'),
          findsOneWidget);
    });

    testWidgets('a file that is not in the folder', (tester) async {
      await open(tester, 'a',
          openInOrgro: (path, {line = 1}) async => OpenResult.noFile);
      await tester.tap(find.byTooltip('Open in Orgro'));
      await tester.pump();
      expect(find.text('Could not find a.org in the folder.'), findsOneWidget);
    });

    testWidgets('on the desktop: "Open in Emacs", at the heading (#116)',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final opened = <(String, int)>[];
      await open(tester, 'p', openInOrgro: (path, {line = 1}) async {
        opened.add((path, line));
        return OpenResult.opened;
      });
      expect(find.byTooltip('Open in Orgro'), findsNothing);
      await tester.tap(find.byTooltip('Open in Emacs'));
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
      final heading = graphOf(notes).nodes['p']!;
      expect(opened, [('b.org', heading.line)]);
      expect(heading.line, greaterThan(1));
      // Emacs goes to the heading: nothing to say.
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('no button without a way to open files', (tester) async {
      await open(tester, 'a');
      expect(find.byTooltip('Open in Orgro'), findsNothing);
    });
  });

  testWidgets('"Share with AI" shares the node, its links and text (#41)',
      (tester) async {
    final shared = <(String, String?)>[];
    await open(tester, 'p',
        shareText: (text, {subject}) async => shared.add((text, subject)));
    await shareNodeWithAi(tester);
    await tester.pump();

    final (text, subject) = shared.single;
    expect(subject, 'Part');
    expect(text, contains('## Part\n\n- ID: p\n- File: b.org\n'));
    // The heading's subtree, not the whole file.
    expect(text, contains('* Part\n'));
    expect(text, contains('Deeper text.'));
    expect(text, isNot(contains('Top text of B.')));
    expect(text, isNot(contains('Other text')));
  });

  testWidgets('a share that fails says so', (tester) async {
    await open(tester, 'a',
        shareText: (text, {subject}) async =>
            throw PlatformException(code: 'x', message: 'no app'));
    await shareNodeWithAi(tester);
    await tester.pump();
    expect(find.text('Could not share the note: no app'), findsOneWidget);
  });

  testWidgets('a file that cannot be read', (tester) async {
    await open(tester, 'a', texts: const {});
    expect(find.text('Could not read a.org.'), findsOneWidget);
    expect(find.text('Backlinks: 2'), findsOneWidget);
  });

  testWidgets('a new graph: the file is read again, or the node is gone',
      (tester) async {
    final graph = ValueNotifier(graphOf(notes));
    final texts = Map.of(notes);
    await open(tester, 'c', graph: graph, texts: texts);
    expect(orgText('See A'), findsOneWidget);

    texts['c.org'] = ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\nChanged.\n';
    graph.value = graphOf(texts);
    await tester.pumpAndSettle();
    expect(orgText('Changed.'), findsOneWidget);

    graph.value = graphOf({'a.org': notes['a.org']!});
    await tester.pumpAndSettle();
    expect(find.text('This node no longer exists.'), findsOneWidget);
  });

  testWidgets('every node of the sample files renders', (tester) async {
    final graph = fixtureGraph();
    final texts = {
      for (final path in graph.files)
        path: File('test/fixtures/roam/$path').readAsStringSync(),
    };
    for (final node in graph.nodes.values) {
      await tester.pumpWidget(MaterialApp(
        home: NodeScreen(
          key: ValueKey(node.id),
          graph: ValueNotifier(graph),
          id: node.id,
          readNote: (path) async => texts[path],
          nodeMemory: MemoryNodeMemory(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: node.file);
      expect(find.textContaining('Could not read'), findsNothing);
      // org_parser finds every heading node that org-roam found.
      expect(find.textContaining('is no longer in'), findsNothing,
          reason: node.id);
    }
  });
}
