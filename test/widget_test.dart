import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/folder_access.dart';
import 'package:roam_graph_mobile/folder/folder_screen.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph/build_graph.dart';
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
  Future<List<String?>> readTexts(List<FolderFile> files) async =>
      [for (final file in files) texts[file.path]];
}

/// Builds the graph right away; tests cannot wait for another isolate.
Future<RoamGraph> buildGraphNow(List<SourceFile> sources) async =>
    buildGraph(sources);

const org = ChosenFolder(uri: 'content://tree/org', name: 'org', hasAccess: true);

List<FolderFile> someFiles() => [
      const FolderFile(path: 'roam', uri: 'content://r', isDirectory: true),
      const FolderFile(path: 'roam/a.org', uri: 'content://a'),
      const FolderFile(path: 'roam/b.org', uri: 'content://b'),
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

Future<void> start(WidgetTester tester, FakeFolderAccess access) async {
  await tester.pumpWidget(
    RoamGraphApp(folderAccess: access, graphBuilder: buildGraphNow),
  );
  await tester.pumpAndSettle();
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
