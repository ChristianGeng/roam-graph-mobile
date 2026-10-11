import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/folder_access.dart';
import 'package:roam_graph_mobile/folder/folder_screen.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/main.dart';

/// A [FolderAccess] without Android, for tests.
class FakeFolderAccess implements FolderAccess {
  FakeFolderAccess({this.saved, this.picked, this.files = const []});

  ChosenFolder? saved;
  ChosenFolder? picked;
  List<FolderFile> files;
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
}

const org = ChosenFolder(uri: 'content://tree/org', name: 'org', hasAccess: true);

List<FolderFile> someFiles() => [
      const FolderFile(path: 'roam', uri: 'content://r', isDirectory: true),
      const FolderFile(path: 'roam/a.org', uri: 'content://a'),
      const FolderFile(path: 'roam/b.org', uri: 'content://b'),
      const FolderFile(path: 'roam/b.sync-conflict-1.org', uri: 'content://c'),
      const FolderFile(path: 'journal/2024.org', uri: 'content://d'),
    ];

Future<void> start(WidgetTester tester, FakeFolderAccess access) async {
  await tester.pumpWidget(RoamGraphApp(folderAccess: access));
  await tester.pumpAndSettle();
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
      ..files = someFiles();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('2'), findsOneWidget);
    expect(find.text('Folder: org'), findsOneWidget);
  });

  testWidgets('without a folder, asks to choose one', (tester) async {
    await start(tester, FakeFolderAccess());

    expect(find.text('Choose your org folder'), findsOneWidget);
    expect(find.text('Choose org folder'), findsOneWidget);
  });

  testWidgets('choosing a folder shows the number of roam files',
      (tester) async {
    final access = FakeFolderAccess(picked: org, files: someFiles());
    await start(tester, access);

    await tester.tap(find.text('Choose org folder'));
    await tester.pumpAndSettle();

    expect(access.pickCalls, 1);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('files indexed in roam/'), findsOneWidget);
    expect(find.text('Folder: org'), findsOneWidget);
  });

  testWidgets('a folder chosen earlier is indexed on start', (tester) async {
    await start(tester, FakeFolderAccess(saved: org, files: someFiles()));

    expect(find.text('2'), findsOneWidget);
    expect(find.text('files indexed in roam/'), findsOneWidget);
  });

  testWidgets('lost access asks for the folder again', (tester) async {
    const lost =
        ChosenFolder(uri: 'content://tree/org', name: 'org', hasAccess: false);
    await start(tester, FakeFolderAccess(saved: lost, files: someFiles()));

    expect(find.text('Access to the folder was lost'), findsOneWidget);
    expect(find.text('Choose org folder'), findsOneWidget);
    expect(find.text('files indexed in roam/'), findsNothing);
  });

  testWidgets('a folder without roam/ is not counted', (tester) async {
    await start(
      tester,
      FakeFolderAccess(saved: org, files: [
        const FolderFile(path: 'ref.org', uri: 'content://ref'),
      ]),
    );

    expect(find.text('No roam/ folder here'), findsOneWidget);
    expect(find.text('files indexed in roam/'), findsNothing);
    expect(find.text('Choose org folder'), findsOneWidget);
  });

  testWidgets('cancelling the picker keeps the current folder', (tester) async {
    final access = FakeFolderAccess(saved: org, files: someFiles());
    await start(tester, access);

    await tester.tap(find.text('Change folder'));
    await tester.pumpAndSettle();

    expect(access.pickCalls, 1);
    expect(find.text('2'), findsOneWidget);
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
      ..files = someFiles();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('2'), findsOneWidget);
  });
}
