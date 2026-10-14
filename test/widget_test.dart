import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/folder_access.dart';
import 'package:roam_graph_mobile/folder/folder_screen.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph/graph_index.dart';
import 'package:roam_graph_mobile/graph/indexer.dart' as indexer;
import 'package:roam_graph_mobile/graph/roam_db.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/main.dart';

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
  Future<List<Uint8List?>> readFiles(List<FolderFile> files) async {
    readPaths.addAll([for (final file in files) file.path]);
    return [
      for (final file in files)
        if (texts[file.path] case final text?) utf8.encode(text) else null,
    ];
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
    if (replace) rebuilds++;
    final graph =
        indexer.updateIndex(db, listing, contents, replace: replace);
    this.folder = folder;
    return graph;
  }
}

const org = ChosenFolder(uri: 'content://tree/org', name: 'org', hasAccess: true);

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

Future<TestGraphIndex> start(WidgetTester tester, FakeFolderAccess access) async {
  final index = TestGraphIndex();
  await tester.pumpWidget(
    RoamGraphApp(folderAccess: access, graphIndex: index),
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

void expectSomeNotes(WidgetTester tester) {
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
  expect(stat(tester, 'unreadable'), isNull);
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

    await tester.tap(find.text('Choose org folder'));
    await tester.pumpAndSettle();

    expect(access.pickCalls, 1);
    expectSomeNotes(tester);
    expect(find.text('Folder: org'), findsOneWidget);
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

    await tester.tap(find.text('Change folder'));
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
    await tester.tap(find.text('Scan again'));
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
    await tester.tap(find.text('Scan again'));
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
    await tester.tap(find.text('Scan again'));
    await tester.pumpAndSettle();

    expect(stat(tester, 'files'), '1');
    expect(stat(tester, 'nodes'), '1');
  });

  testWidgets('rebuilding the index reads every file again', (tester) async {
    final access = withNotes(saved: org);
    final index = await start(tester, access);
    expect(index.rebuilds, 1); // the first index of a folder

    await tester.tap(find.text('Rebuild index'));
    await tester.pumpAndSettle();

    expect(index.rebuilds, 2);
    expect(access.readPaths, hasLength(4));
    expectSomeNotes(tester);
  });

  testWidgets('a failed rebuild keeps the old index', (tester) async {
    final access = withNotes(saved: org);
    final index = await start(tester, access);

    access.listError = PlatformException(code: 'io', message: 'gone');
    await tester.tap(find.text('Rebuild index'));
    await tester.pumpAndSettle();

    expect(index.db.storedFiles().keys, unorderedEquals(['a.org', 'b.org']));
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
    await tester.tap(find.text('Change folder'));
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
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expectSomeNotes(tester);
  });
}
