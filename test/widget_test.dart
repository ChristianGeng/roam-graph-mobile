import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/capture/share_inbox.dart';
import 'package:roam_graph_mobile/folder/folder_access.dart';
import 'package:roam_graph_mobile/folder/folder_screen.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph/graph_index.dart';
import 'package:roam_graph_mobile/graph/indexer.dart' as indexer;
import 'package:roam_graph_mobile/graph/roam_db.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/main.dart';

import 'graph_view/graph_screen_test.dart' show MemoryNodeMemory, layoutHere;

/// A [FolderAccess] without Android, for tests.
class FakeFolderAccess implements FolderAccess {
  FakeFolderAccess({
    this.saved,
    this.picked,
    this.files = const [],
    this.texts = const {},
  });

  ChosenFolder? saved;
  ChosenFolder? picked;
  List<FolderFile> files;

  /// File contents by path; a missing path cannot be read.
  Map<String, String> texts;
  PlatformException? listError;
  int pickCalls = 0;

  /// Whether the app to open files with is installed, and the paths it
  /// was asked to show, with the app.
  bool appInstalled = true;
  final opened = <(String, String)>[];

  /// The files created, as directory URI and name.
  final created = <(String, String)>[];

  /// Whether every new file's name counts as taken.
  bool everyNameTaken = false;

  /// An error listing the folder will give after the next file is
  /// created.
  PlatformException? listErrorAfterCreate;

  /// The paths of every file read, in order.
  final readPaths = <String>[];

  @override
  Future<ChosenFolder?> savedFolder() async => saved;

  @override
  Future<ChosenFolder?> pickFolder() async {
    pickCalls++;
    return picked;
  }

  @override
  Future<List<FolderFile>> listFiles(ChosenFolder folder) async {
    final error = listError;
    if (error != null) throw error;
    return files;
  }

  @override
  Future<String> createFile(String dir, String name, Uint8List bytes) async {
    // The test folders keep their notes in roam/.
    final path = 'roam/$name';
    if (everyNameTaken || files.any((f) => f.path == path)) {
      throw PlatformException(code: 'exists', message: '$name exists');
    }
    created.add((dir, name));
    listError = listErrorAfterCreate;
    final uri = 'content://new/$name';
    files = [...files, FolderFile(path: path, uri: uri, modified: 1)];
    texts = {...texts, path: utf8.decode(bytes)};
    return uri;
  }

  @override
  Future<bool> openWith(FolderFile file, String packageName) async {
    if (!appInstalled) return false;
    opened.add((file.path, packageName));
    return true;
  }

  @override
  Future<List<Uint8List?>> readFiles(List<FolderFile> files) async {
    readPaths.addAll([for (final file in files) file.path]);
    return [
      for (final file in files)
        if (texts[file.path] case final text?) utf8.encode(text) else null,
    ];
  }
}

/// A [ShareInbox] without Android, for tests: a queue, as in
/// MainActivity.kt.
class FakeShareInbox implements ShareInbox {
  final queue = <SharedText>[];
  void Function()? onArrived;

  @override
  Future<SharedText?> take() async =>
      queue.isEmpty ? null : queue.removeAt(0);

  @override
  void listen(void Function() onArrived) => this.onArrived = onArrived;

  /// Text shared while the app runs.
  void share(SharedText shared) {
    queue.add(shared);
    onArrived?.call();
  }
}

/// A [GraphIndex] on a real org-roam database in memory, without another
/// isolate, which tests cannot wait for.
class TestGraphIndex implements GraphIndex {
  final db = RoamDatabase.inMemory(root: '/roam');
  String? folder;
  int rebuilds = 0;

  @override
  Future<String?> indexedFolder() async => folder;

  @override
  Future<List<String>> filesToRead(indexer.Listing listing) async =>
      indexer.filesToRead(db, listing);

  @override
  Future<RoamGraph> update(
    indexer.Listing listing,
    Map<String, Uint8List?> contents, {
    required String folder,
    bool replace = false,
  }) async {
    final sameFolder = this.folder == folder;
    if (replace || !sameFolder) rebuilds++;
    final graph = indexer.updateIndex(db, listing, contents,
        replace: replace || !sameFolder, keepUnreadable: sameFolder);
    this.folder = folder;
    return graph;
  }
}

const org = ChosenFolder(uri: 'content://tree/org', name: 'org', hasAccess: true);

/// The same folder, chosen since v2 with write access.
const writableOrg = ChosenFolder(
    uri: 'content://tree/org', name: 'org', hasAccess: true, canWrite: true);

List<FolderFile> someFiles() => [
      const FolderFile(path: 'roam', uri: 'content://r', isDirectory: true),
      const FolderFile(path: 'roam/a.org', uri: 'content://a', modified: 1),
      const FolderFile(path: 'roam/b.org', uri: 'content://b', modified: 1),
      const FolderFile(path: 'roam/b.sync-conflict-1.org', uri: 'content://c'),
      const FolderFile(path: 'journal/2024.org', uri: 'content://d'),
    ];

/// Two notes: a links to b and to a note that does not exist.
const someTexts = {
  'roam/a.org': ':PROPERTIES:\n:ID: a\n:ROAM_ALIASES: Alpha\n:END:\n'
      '#+title: A\n[[id:b]] [[id:gone]]\n',
  'roam/b.org': ':PROPERTIES:\n:ID: b\n:ROAM_REFS: https://example.com\n'
      ':END:\n#+title: B\n#+filetags: :x:\n'
      '* Heading\n:PROPERTIES:\n:ID: h\n:END:\n',
};

FakeFolderAccess withNotes({ChosenFolder? saved, ChosenFolder? picked}) =>
    FakeFolderAccess(
      saved: saved,
      picked: picked,
      files: someFiles(),
      texts: someTexts,
    );

Future<TestGraphIndex> start(
  WidgetTester tester,
  FakeFolderAccess access, {
  FakeShareInbox? shares,
  MemoryNodeMemory? memory,
}) async {
  final index = TestGraphIndex();
  final nodeMemory = memory ?? MemoryNodeMemory();
  await tester.pumpWidget(
    RoamGraphApp(
      folderAccess: access,
      graphIndex: index,
      shareInbox: shares ?? FakeShareInbox(),
      nodeMemory: nodeMemory,
      graphScreen: (graph, readNote, openInOrgro, writer) => GraphScreen(
        graph: graph,
        readNote: readNote,
        openInOrgro: openInOrgro,
        writer: writer,
        nodeMemory: nodeMemory,
        computeLayout: layoutHere,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return index;
}

/// The value shown for one count, or null if it is not shown.
String? stat(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey('stat-$key'));
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Text>(finder).data;
}

/// Scrolls the button with [text] into view, as on a small screen, and
/// taps it.
Future<void> tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.pump();
  await tester.tap(find.text(text));
}

/// The counts of [someTexts]. [unreadable] is the number of files shown as
/// unreadable, if any.
void expectSomeNotes(WidgetTester tester, {String? unreadable}) {
  expect(stat(tester, 'files'), '2');
  expect(stat(tester, 'nodes'), '3');
  expect(stat(tester, 'file-nodes'), '2');
  expect(stat(tester, 'heading-nodes'), '1');
  expect(stat(tester, 'links'), '2');
  expect(stat(tester, 'dangling'), '1');
  // b's file tag, and the heading inherits it.
  expect(stat(tester, 'tags'), '2');
  expect(stat(tester, 'refs'), '1');
  expect(stat(tester, 'aliases'), '1');
  expect(stat(tester, 'duplicates'), isNull);
  expect(stat(tester, 'unreadable'), unreadable);
}

void main() {
  testWidgets('the app shows its build version', (tester) async {
    await start(tester, FakeFolderAccess());

    // Tests run without --dart-define=APP_VERSION, so the version is "dev".
    expect(appVersion, 'dev');
    expect(find.text('Version dev'), findsOneWidget);
  });

  testWidgets('the screen shows the version it is given', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FolderScreen(folderAccess: FakeFolderAccess(), version: '0.1.42'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Version 0.1.42'), findsOneWidget);
    expect(find.text('Version dev'), findsNothing);
  });

  testWidgets('on resume, a newly saved folder is indexed', (tester) async {
    final access = FakeFolderAccess();
    await start(tester, access);
    expect(find.text('Choose your org folder'), findsOneWidget);

    // A folder chosen while Android had recreated the app.
    access
      ..saved = org
      ..files = someFiles()
      ..texts = someTexts;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(stat(tester, 'files'), '2');
    expect(find.text('Folder: org'), findsOneWidget);
  });

  testWidgets('without a folder, asks to choose one', (tester) async {
    await start(tester, FakeFolderAccess());

    expect(find.text('Choose your org folder'), findsOneWidget);
    expect(find.text('Choose org folder'), findsOneWidget);
  });

  testWidgets('choosing a folder shows the graph counts', (tester) async {
    final access = withNotes(picked: org);
    await start(tester, access);

    await tapText(tester, 'Choose org folder');
    await tester.pumpAndSettle();

    expect(access.pickCalls, 1);
    expectSomeNotes(tester);
    expect(find.text('Folder: org'), findsOneWidget);
  });

  testWidgets('"Show graph" opens the graph of the indexed notes',
      (tester) async {
    final access = withNotes(saved: org);
    await start(tester, access);

    await tapText(tester, 'Show graph');
    await tester.pumpAndSettle();

    expect(find.text('Whole graph'), findsOneWidget);
    // Centred on a, the node with the most links. Its node view reads
    // a.org from the folder.
    await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('A')),
        findsOneWidget);
    expect(find.textContaining('id:b', findRichText: true), findsWidgets);
    expect(access.readPaths.last, 'roam/a.org');
  });

  testWidgets('an open graph shows what a scan on resume found',
      (tester) async {
    final access = withNotes(saved: org);
    await start(tester, access);
    await tapText(tester, 'Show graph');
    await tester.pumpAndSettle();

    // Syncthing brought c, which links to a and b.
    access
      ..files = [
        ...someFiles(),
        const FolderFile(path: 'roam/c.org', uri: 'content://c2', modified: 1),
      ]
      ..texts = {
        ...someTexts,
        'roam/c.org': ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\n'
            '[[id:a]] [[id:b]]\n',
      };
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    // Still on a, which c now links to.
    await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('A')),
        findsOneWidget);
    expect(find.text('Backlinks: 1'), findsOneWidget);
  });

  testWidgets('"Open in Orgro" hands the file to Orgro, or says it is missing',
      (tester) async {
    final access = withNotes(saved: org);
    await start(tester, access);
    await tapText(tester, 'Show graph');
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open in Orgro'));
    await tester.pumpAndSettle();
    expect(access.opened, [('roam/a.org', 'com.madlonkay.orgro')]);

    access.appInstalled = false;
    await tester.tap(find.byTooltip('Open in Orgro'));
    await tester.pump();
    expect(find.text('Orgro is not installed.'), findsOneWidget);
  });

  group('capture (#11)', () {
    Future<FakeFolderAccess> openCapture(
        WidgetTester tester, ChosenFolder folder) async {
      final access = withNotes(saved: folder, picked: writableOrg);
      await start(tester, access);
      await tapText(tester, 'Show graph');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New node'));
      await tester.pumpAndSettle();
      return access;
    }

    testWidgets('a new node is written as org-roam would, indexed and opened',
        (tester) async {
      final access = await openCapture(tester, writableOrg);
      await tester.enterText(
          find.byKey(const ValueKey('capture-title')), 'Crème brûlée');
      await tester.enterText(
          find.byKey(const ValueKey('capture-tags')), 'food, french');
      await tester.enterText(
          find.byKey(const ValueKey('capture-body')), 'Burnt cream.');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      final (dir, name) = access.created.single;
      // Into roam/ itself, named as org-roam's default capture template.
      expect(dir, 'content://r');
      expect(name, matches(RegExp(r'^\d{14}-creme_brulee\.org$')));
      final text = access.texts['roam/$name']!;
      expect(text, startsWith(':PROPERTIES:\n:ID:       '));
      expect(text, contains('#+title: Crème brûlée\n#+filetags: :food:french:'));
      expect(text, endsWith('\nBurnt cream.\n'));
      // Indexed at once, and opened.
      expect(access.readPaths, contains('roam/$name'));
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.text('Crème brûlée')),
          findsOneWidget);
    });

    testWidgets('a folder chosen before v2 must be chosen again',
        (tester) async {
      final access = await openCapture(tester, org);
      await tester.enterText(
          find.byKey(const ValueKey('capture-title')), 'Idea');
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(access.created, isEmpty);
      expect(find.textContaining('may only read the folder'), findsOneWidget);
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();
      expect(access.pickCalls, 1);

      // Now with write access.
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(access.created, hasLength(1));
    });

    testWidgets('written but not indexed: said so, and not written twice',
        (tester) async {
      final access = await openCapture(tester, writableOrg);
      access.listErrorAfterCreate =
          PlatformException(code: 'io', message: 'listing failed');
      await tester.enterText(
          find.byKey(const ValueKey('capture-title')), 'Saved');
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(access.created, hasLength(1));
      expect(find.textContaining('Saved as roam/'), findsOneWidget);
      expect(find.textContaining('listing failed'), findsOneWidget);
      // Still here, and Save is off: a second tap writes nothing.
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(access.created, hasLength(1));
    });

    testWidgets('another folder without roam/ does not get the capture',
        (tester) async {
      final access = await openCapture(tester, org);
      await tester.enterText(
          find.byKey(const ValueKey('capture-title')), 'Idea');
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('may only read the folder'), findsOneWidget);

      // The folder chosen now is writable but has no roam/.
      access
        ..picked = const ChosenFolder(
            uri: 'content://tree/other',
            name: 'other',
            hasAccess: true,
            canWrite: true)
        ..files = [const FolderFile(path: 'ref.org', uri: 'content://ref')];
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(access.created, isEmpty);
      expect(find.textContaining('No folder is indexed'), findsOneWidget);
    });

    testWidgets('a file name that is taken is not overwritten',
        (tester) async {
      final access = await openCapture(tester, writableOrg);
      access.everyNameTaken = true;
      await tester.enterText(
          find.byKey(const ValueKey('capture-title')), 'Twice');
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(access.created, isEmpty);
      expect(find.textContaining('exists already'), findsOneWidget);
      // Still on the capture screen, to save again.
      expect(find.byKey(const ValueKey('capture-title')), findsOneWidget);
    });
  });

  group('link to the current node (#12)', () {
    Future<FakeFolderAccess> showA(WidgetTester tester) async {
      final access = withNotes(saved: writableOrg);
      await start(tester, access);
      await tapText(tester, 'Show graph');
      await tester.pumpAndSettle();
      // The test screen is a tablet in landscape: a is in the side pane.
      return access;
    }

    testWidgets('a node captured from a node links to it, in the new file',
        (tester) async {
      final access = await showA(tester);
      final textOfA = access.texts['roam/a.org'];
      await tester.tap(find.byTooltip('New node from here'));
      await tester.pumpAndSettle();
      expect(find.text('Link to A'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('capture-title')), 'Child');
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      final (_, name) = access.created.single;
      final text = access.texts['roam/$name']!;
      expect(text, contains('\n[[id:a][A]]\n'));
      // The existing file is not changed.
      expect(access.texts['roam/a.org'], textOfA);

      // The new node is open; back on a, it is a backlink.
      expect(find.descendant(
              of: find.byType(AppBar), matching: find.text('Child')),
          findsOneWidget);
      // The side pane's Back, not the page's.
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('node-pane')),
          matching: find.byTooltip('Back')));
      await tester.pumpAndSettle();
      expect(find.text('Backlinks: 1'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Child'), findsOneWidget);
    });

    testWidgets('the link can be left out', (tester) async {
      final access = await showA(tester);
      await tester.tap(find.byTooltip('New node from here'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Link to A'));
      await tester.enterText(
          find.byKey(const ValueKey('capture-title')), 'Alone');
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final (_, name) = access.created.single;
      expect(access.texts['roam/$name'], isNot(contains('[[id:')));
    });

    testWidgets('from the graph, the link to the selected node is on',
        (tester) async {
      await showA(tester);
      await tester.tap(find.byTooltip('New node'));
      await tester.pumpAndSettle();
      final tile = tester.widget<CheckboxListTile>(
          find.byKey(const ValueKey('capture-link')));
      expect(tile.value, isTrue);
      expect(find.text('Link to A'), findsOneWidget);
    });
  });

  group('safe writes next to Syncthing (#13)', () {
    testWidgets('conflict copies are counted, listed and reported',
        (tester) async {
      // someFiles() has roam/b.sync-conflict-1.org next to roam/b.org.
      final access = withNotes(saved: org);
      await start(tester, access);
      expect(stat(tester, 'conflicts'), '1');
      expect(find.text('roam/b.sync-conflict-1.org'), findsOneWidget);
      // The copy is no node: the counts are those of the notes alone.
      expectSomeNotes(tester);
      // This screen lists it; no message on top.
      expect(find.byType(SnackBar), findsNothing);

      // In the graph, Syncthing makes another one; it is reported there.
      await tapText(tester, 'Show graph');
      await tester.pumpAndSettle();
      access.files = [
        ...access.files,
        const FolderFile(
            path: 'roam/a.sync-conflict-20261015-101010-ABCDEFG.org',
            uri: 'content://ac'),
      ];
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Syncthing made a new conflict copy'),
          findsOneWidget);
    });

    testWidgets('a new copy is reported, also when another was resolved',
        (tester) async {
      final access = withNotes(saved: org);
      await start(tester, access);
      await tapText(tester, 'Show graph');
      await tester.pumpAndSettle();

      // b's copy is resolved in Emacs, and Syncthing makes one of a.
      access.files = [
        for (final file in access.files)
          if (!file.path.contains('.sync-conflict-')) file,
        const FolderFile(
            path: 'roam/a.sync-conflict-20261015-101010-ABCDEFG.org',
            uri: 'content://ac'),
      ];
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Syncthing made a new conflict copy'),
          findsOneWidget);
    });

    testWidgets('a folder without roam/ still lists its conflict copies',
        (tester) async {
      await start(
        tester,
        FakeFolderAccess(saved: org, files: [
          const FolderFile(
              path: 'agenda/a.sync-conflict-20261015-101010-ABCDEFG.org',
              uri: 'content://a'),
        ]),
      );
      expect(find.text('No roam/ folder here'), findsOneWidget);
      expect(find.text('agenda/a.sync-conflict-20261015-101010-ABCDEFG.org'),
          findsOneWidget);
    });

    testWidgets('every conflict copy is listed, not only ten', (tester) async {
      final access = withNotes(saved: org);
      access.files = [
        ...access.files,
        for (var i = 10; i < 22; i++)
          FolderFile(
              path: 'roam/n$i.sync-conflict-20261015-1010$i-ABCDEFG.org',
              uri: 'content://n$i'),
      ];
      await start(tester, access);
      expect(stat(tester, 'conflicts'), '13');
      await tester.scrollUntilVisible(
          find.text('roam/n21.sync-conflict-20261015-101021-ABCDEFG.org'),
          200);
      expect(find.textContaining(' more'), findsNothing);
    });

    testWidgets('several nodes captured in quick succession', (tester) async {
      final access = withNotes(saved: writableOrg);
      await start(tester, access);
      await tapText(tester, 'Show graph');
      await tester.pumpAndSettle();
      for (var i = 1; i <= 5; i++) {
        await tester.tap(find.byTooltip('New node'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('capture-title')), 'Quick $i');
        await tester.pump();
        await tester.tap(find.byTooltip('Save'));
        await tester.pumpAndSettle();
      }

      // Five files, each written once, none overwritten.
      final names = [for (final (_, name) in access.created) name];
      expect(names, hasLength(5));
      expect(names.toSet(), hasLength(5));
      for (var i = 1; i <= 5; i++) {
        expect(names.where((n) => n.endsWith('-quick_$i.org')), hasLength(1));
        final text = access.texts['roam/${names[i - 1]}']!;
        expect(text, contains('#+title: Quick $i\n'));
      }
      // All indexed, no conflict copies and no temporary files.
      for (final name in names) {
        expect(access.readPaths, contains('roam/$name'));
      }
      expect(conflictCopies(access.files), ['roam/b.sync-conflict-1.org']);
      expect(access.files.where((f) => f.path.contains('.syncthing.')),
          isEmpty);
    });
  });

  group('shared text becomes a new node (#15)', () {
    testWidgets('a share at start opens the capture, proposed and saved',
        (tester) async {
      final shares = FakeShareInbox()
        ..queue.add(const SharedText('# Attention\nIs all you need.'));
      final access = withNotes(saved: writableOrg);
      await start(tester, access,
          shares: shares, memory: MemoryNodeMemory('a'));

      expect(find.text('New node'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Attention'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Is all you need.'), findsOneWidget);
      // A link to the node viewed last is offered, not on.
      final link = tester.widget<CheckboxListTile>(
          find.byKey(const ValueKey('capture-link')));
      expect(link.value, isFalse);
      expect(find.text('Link to A'), findsOneWidget);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final (_, name) = access.created.single;
      expect(name, matches(RegExp(r'^\d{14}-attention\.org$')));
      expect(access.texts['roam/$name'],
          contains('#+title: Attention\n\nIs all you need.\n'));
      // The new node is open.
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.text('Attention')),
          findsOneWidget);
      expect(shares.queue, isEmpty);
    });

    testWidgets('a share while the app runs', (tester) async {
      final shares = FakeShareInbox();
      await start(tester, withNotes(saved: writableOrg), shares: shares);
      expect(find.text('New node'), findsNothing);

      shares.share(const SharedText('Later', subject: 'From Claude'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'From Claude'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Later'), findsOneWidget);
    });

    testWidgets('two shares before indexing: both, one after the other',
        (tester) async {
      final shares = FakeShareInbox()
        ..queue.addAll(const [SharedText('First'), SharedText('Second')]);
      final access = withNotes(saved: writableOrg);
      await start(tester, access, shares: shares);

      expect(find.widgetWithText(TextField, 'First'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Second'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect([for (final (_, name) in access.created) name.substring(15)],
          ['first.org', 'second.org']);
    });

    testWidgets('a share during a capture opens when the capture closes',
        (tester) async {
      final shares = FakeShareInbox()..queue.add(const SharedText('One'));
      await start(tester, withNotes(saved: writableOrg), shares: shares);
      expect(find.widgetWithText(TextField, 'One'), findsOneWidget);

      shares.share(const SharedText('Two'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Two'), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Two'), findsOneWidget);
    });

    testWidgets('a share waits until a folder is indexed', (tester) async {
      final shares = FakeShareInbox()..queue.add(const SharedText('Waiting'));
      final access = withNotes(picked: writableOrg);
      await start(tester, access, shares: shares);
      expect(find.text('Choose your org folder'), findsOneWidget);
      expect(shares.queue, isNotEmpty);

      await tapText(tester, 'Choose org folder');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Waiting'), findsOneWidget);
    });
  });

  testWidgets('without nodes, the graph says so and offers a first node',
      (tester) async {
    final access = FakeFolderAccess(saved: writableOrg, files: [
      const FolderFile(path: 'roam', uri: 'content://r', isDirectory: true),
      const FolderFile(path: 'roam/x.org', uri: 'content://x', modified: 1),
    ], texts: {
      'roam/x.org': '#+title: Not a node\n',
    });
    await start(tester, access);
    expect(stat(tester, 'nodes'), '0');

    await tapText(tester, 'Show graph');
    await tester.pumpAndSettle();
    expect(find.text('There are no nodes in roam/.'), findsOneWidget);
    await tester.tap(find.byTooltip('New node'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('capture-title')), 'First');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(access.created, hasLength(1));
    expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('First')),
        findsOneWidget);
  });

  testWidgets('a folder chosen earlier is indexed on start', (tester) async {
    await start(tester, withNotes(saved: org));

    expectSomeNotes(tester);
  });

  testWidgets('with roam/ itself chosen, the same graph is found',
      (tester) async {
    const roam =
        ChosenFolder(uri: 'content://tree/roam', name: 'roam', hasAccess: true);
    await start(
      tester,
      FakeFolderAccess(
        saved: roam,
        files: [
          const FolderFile(path: 'a.org', uri: 'content://a'),
          const FolderFile(path: 'b.org', uri: 'content://b'),
        ],
        texts: {
          for (final entry in someTexts.entries)
            entry.key.substring('roam/'.length): entry.value,
        },
      ),
    );

    expectSomeNotes(tester);
  });

  testWidgets('files that cannot be read are counted', (tester) async {
    await start(
      tester,
      FakeFolderAccess(
        saved: org,
        files: someFiles(),
        texts: {'roam/a.org': someTexts['roam/a.org']!},
      ),
    );

    expect(stat(tester, 'files'), '1');
    expect(stat(tester, 'unreadable'), '1');
    // Named, relative to roam/, so it can be found.
    expect(find.text('b.org'), findsOneWidget);
  });

  testWidgets('a file org-roam skips is counted and named', (tester) async {
    await start(
      tester,
      FakeFolderAccess(
        saved: org,
        files: someFiles(),
        texts: {
          'roam/a.org': someTexts['roam/a.org']!,
          'roam/b.org': ':PROPERTIES:\n:ID: b\n:ROAM_ALIASES: "open\n:END:\n',
        },
      ),
    );

    expect(stat(tester, 'files'), '1');
    expect(stat(tester, 'skipped'), '1');
    expect(find.textContaining('b.org: Unterminated quote'), findsOneWidget);
  });

  testWidgets('an ID used twice is reported', (tester) async {
    await start(
      tester,
      FakeFolderAccess(
        saved: org,
        files: someFiles(),
        texts: {
          'roam/a.org': ':PROPERTIES:\n:ID: same\n:END:\n',
          'roam/b.org': ':PROPERTIES:\n:ID: same\n:END:\n',
        },
      ),
    );

    expect(stat(tester, 'nodes'), '1');
    expect(stat(tester, 'duplicates'), '1');
  });

  testWidgets('lost access asks for the folder again', (tester) async {
    const lost =
        ChosenFolder(uri: 'content://tree/org', name: 'org', hasAccess: false);
    await start(tester, withNotes(saved: lost));

    expect(find.text('Access to the folder was lost'), findsOneWidget);
    expect(find.text('Choose org folder'), findsOneWidget);
    expect(stat(tester, 'files'), isNull);
  });

  testWidgets('a folder without roam/ is not counted', (tester) async {
    await start(
      tester,
      FakeFolderAccess(saved: org, files: [
        const FolderFile(path: 'ref.org', uri: 'content://ref'),
      ]),
    );

    expect(find.text('No roam/ folder here'), findsOneWidget);
    expect(stat(tester, 'files'), isNull);
    expect(find.text('Choose org folder'), findsOneWidget);
  });

  testWidgets('cancelling the picker keeps the current folder', (tester) async {
    final access = withNotes(saved: org);
    await start(tester, access);

    await tapText(tester, 'Change folder');
    await tester.pumpAndSettle();

    expect(access.pickCalls, 1);
    expectSomeNotes(tester);
    expect(find.text('Folder: org'), findsOneWidget);
  });

  testWidgets('a second scan reads only new and changed files',
      (tester) async {
    final access = withNotes(saved: org);
    await start(tester, access);
    expect(access.readPaths, ['roam/a.org', 'roam/b.org']);

    // Nothing changed: nothing is read.
    await tapText(tester, 'Scan again');
    await tester.pumpAndSettle();
    expect(access.readPaths, hasLength(2));
    expectSomeNotes(tester);

    // b.org changed: only b.org is read, and the change shows.
    access
      ..files = [
        for (final f in someFiles())
          f.path == 'roam/b.org'
              ? FolderFile(path: f.path, uri: f.uri, modified: 1000)
              : f,
      ]
      ..texts = {
        ...someTexts,
        'roam/b.org': ':PROPERTIES:\n:ID: b\n:END:\n#+title: B\n',
      };
    await tapText(tester, 'Scan again');
    await tester.pumpAndSettle();
    expect(access.readPaths.skip(2), ['roam/b.org']);
    expect(stat(tester, 'nodes'), '2');
    expect(stat(tester, 'refs'), '0');
  });

  testWidgets('a file that is gone leaves the graph', (tester) async {
    final access = withNotes(saved: org);
    await start(tester, access);

    access.files = [
      for (final f in someFiles())
        if (f.path != 'roam/b.org') f,
    ];
    await tapText(tester, 'Scan again');
    await tester.pumpAndSettle();

    expect(stat(tester, 'files'), '1');
    expect(stat(tester, 'nodes'), '1');
  });

  testWidgets('rebuilding the index reads every file again', (tester) async {
    final access = withNotes(saved: org);
    final index = await start(tester, access);
    expect(index.rebuilds, 1); // the first index of a folder

    await tapText(tester, 'Rebuild index');
    await tester.pumpAndSettle();

    expect(index.rebuilds, 2);
    expect(access.readPaths, hasLength(4));
    expectSomeNotes(tester);
  });

  testWidgets('a failed rebuild keeps the old index', (tester) async {
    final access = withNotes(saved: org);
    final index = await start(tester, access);

    access.listError = PlatformException(code: 'io', message: 'gone');
    await tapText(tester, 'Rebuild index');
    await tester.pumpAndSettle();

    expect(index.db.storedFiles().keys, unorderedEquals(['a.org', 'b.org']));
  });

  testWidgets('a rebuild keeps a file it cannot read', (tester) async {
    final access = withNotes(saved: org);
    final index = await start(tester, access);

    access.texts = {'roam/a.org': someTexts['roam/a.org']!};
    await tapText(tester, 'Rebuild index');
    await tester.pumpAndSettle();

    expect(index.db.storedFiles().keys, unorderedEquals(['a.org', 'b.org']));
    // b's stored rows stay, so the counts do not change; b is reported.
    expectSomeNotes(tester, unreadable: '1');
    expect(find.text('b.org'), findsOneWidget);
  });

  testWidgets('roam/ appearing later is found on resume', (tester) async {
    final access = withNotes(saved: org);
    final files = access.files;
    access.files = [const FolderFile(path: 'ref.org', uri: 'content://ref')];
    await start(tester, access);
    expect(find.text('No roam/ folder here'), findsOneWidget);

    access.files = files;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expectSomeNotes(tester);
  });

  testWidgets('another folder replaces the index, even with the same files',
      (tester) async {
    final access = withNotes(saved: org);
    final index = await start(tester, access);
    expect(index.folder, org.uri);

    // Same paths and times as before, other content.
    const other =
        ChosenFolder(uri: 'content://tree/other', name: 'org', hasAccess: true);
    access
      ..picked = other
      ..texts = {
        'roam/a.org': ':PROPERTIES:\n:ID: other-a\n:END:\n',
        'roam/b.org': ':PROPERTIES:\n:ID: other-b\n:END:\n',
      };
    await tapText(tester, 'Change folder');
    await tester.pumpAndSettle();

    expect(index.folder, other.uri);
    expect(access.readPaths.skip(2), ['roam/a.org', 'roam/b.org']);
    expect(index.db.loadGraph().nodes.keys,
        unorderedEquals(['other-a', 'other-b']));
  });

  testWidgets('coming back to the app indexes again', (tester) async {
    final access = withNotes(saved: org);
    await start(tester, access);

    access.texts = {
      ...someTexts,
      'roam/c.org': ':PROPERTIES:\n:ID: c\n:END:\n',
    };
    access.files = [
      ...someFiles(),
      const FolderFile(path: 'roam/c.org', uri: 'content://e'),
    ];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(access.readPaths.last, 'roam/c.org');
    expect(stat(tester, 'files'), '3');
  });

  testWidgets('a read error is shown, with a way to try again',
      (tester) async {
    final access = FakeFolderAccess(saved: org)
      ..listError = PlatformException(code: 'list_failed', message: 'boom');
    await start(tester, access);

    expect(find.text('Could not read the folder'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);

    access
      ..listError = null
      ..files = someFiles()
      ..texts = someTexts;
    await tapText(tester, 'Try again');
    await tester.pumpAndSettle();

    expectSomeNotes(tester);
  });
}
