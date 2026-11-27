import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/node_view/scripts.dart';
import 'package:roam_graph_mobile/settings/keys.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

void main() {
  group('a change made before the file is read (#296, #310, #315)', () {
    const inFile = ViewSettings(theme: AppTheme.dark);

    testWidgets("is saved only once the file is read, with the "
        "file's other settings", (tester) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, _light);
      await tester.pump();
      // Used at once, on the defaults; the file is not written yet.
      expect(
        ViewSettingsScope.read(context),
        _light(ViewSettings.withDefaults()),
      );
      expect(store.waiting, 0);

      store.finishLoad();
      await tester.pump();
      final kept = _light(_richFile);
      expect(ViewSettingsScope.read(context), kept);
      expect(store.settings.toJson(), _richFile.toJson());
      store.finishSave();
      await change;
      expect(store.settings.toJson(), kept.toJson());

      // A later failed save goes back to these settings.
      await tester.pump();
      final failing = ViewSettingsScope.change(context, _neverScripts);
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(failing, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), kept);
    });

    testWidgets('whose save fails: the file is shown, and left as it was', (
      tester,
    ) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, _light);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(change, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), inFile);
      expect(store.settings, inFile);
    });

    testWidgets("several changes: all are made on the file's settings, "
        "saved in order", (tester) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, _light);
      final second = ViewSettingsScope.change(context, _neverScripts);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      final kept = _neverScripts(_light(_richFile));
      expect(ViewSettingsScope.read(context), kept);
      store.finishSave();
      await first;
      expect(store.settings.toJson(), _light(_richFile).toJson());
      await tester.pump();
      store.finishSave();
      await second;
      expect(store.settings.toJson(), kept.toJson());
    });

    testWidgets('a saved change, then a failed one: the file gets the '
        'saved change and keeps its other settings', (tester) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, _light);
      final second = ViewSettingsScope.change(context, _neverScripts);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave();
      await first;
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(second, throwsA(isA<FileSystemException>()));
      await tester.pump();

      final kept = _light(_richFile);
      expect(ViewSettingsScope.read(context), kept);
      expect(store.settings.toJson(), kept.toJson());
    });

    testWidgets("only the last update check: the file's settings are kept", (
      tester,
    ) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);

      final checked = DateTime.utc(2026, 11, 24, 8);
      final change = ViewSettingsScope.change(
        context,
        (s) => s.copyWith(lastUpdateCheckTime: checked),
      );
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), _richFile);
      store.finishSave();
      await change;
      expect(
        store.settings.toJson(),
        _richFile.copyWith(lastUpdateCheckTime: checked).toJson(),
      );
    });

    testWidgets("a field set to the value shown is kept, not the file's", (
      tester,
    ) async {
      final file = _richFile.copyWith(graphShare: 0.6, graphCollapsed: true);
      final store = _GatedStore(file);
      final context = await _host(tester, store);

      // As a double tap on the divider: the default split, unfolded.
      ViewSettings reset(ViewSettings s) => s.copyWith(
        graphShare: ViewSettings.defaultGraphShare,
        graphCollapsed: false,
      );
      final change = ViewSettingsScope.change(context, reset);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), reset(file));
      store.finishSave();
      await change;
      expect(store.settings.toJson(), reset(file).toJson());
    });

    testWidgets("a field set, then back to its default: the default, "
        "not the file's value", (tester) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, _light);
      final second = ViewSettingsScope.change(
        context,
        (s) => s.copyWith(theme: AppTheme.system),
      );
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      final kept = _richFile.copyWith(theme: AppTheme.system);
      expect(ViewSettingsScope.read(context), kept);
      store.finishSave();
      await first;
      await tester.pump();
      store.finishSave();
      await second;
      expect(store.settings.toJson(), kept.toJson());
    });

    testWidgets("a key changed keeps the file's other keys", (tester) async {
      final file = _richFile.copyWith(
        keys: const KeyBindings().withKey(KeyAction.undo, _f5),
      );
      final store = _GatedStore(file);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(
        context,
        (s) => s.copyWith(
          keys: s.keys.withKey(KeyAction.searchInNote, _f6),
        ),
      );
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      final keys = ViewSettingsScope.read(context).keys;
      expect(keys.of(KeyAction.undo), _f5);
      expect(keys.of(KeyAction.searchInNote), _f6);
      expect(ViewSettingsScope.read(context).theme, AppTheme.dark);
      store.finishSave();
      await change;
      expect(store.settings.keys, keys);
    });

    testWidgets("a key reset is reset in the file's keys too (#315)", (
      tester,
    ) async {
      final file = _richFile.copyWith(
        keys: const KeyBindings().withKey(KeyAction.undo, _f5),
      );
      final store = _GatedStore(file);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(
        context,
        (s) => s.copyWith(keys: s.keys.reset(KeyAction.undo)),
      );
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave();
      await change;
      expect(store.settings.toJson(), _richFile.toJson());
    });

    testWidgets('a key that another action has in the file: refused; a '
        'later change is saved without it (#315)', (tester) async {
      final file = _richFile.copyWith(
        keys: const KeyBindings().withKey(KeyAction.undo, _f5),
      );
      final store = _GatedStore(file);
      final context = await _host(tester, store);

      // Free in the defaults shown, taken in the file.
      final refused = ViewSettingsScope.change(
        context,
        (s) => s.copyWith(
          keys: s.keys.withKey(KeyAction.searchInNote, _f5),
        ),
      );
      final later = ViewSettingsScope.change(context, _light);
      // Listened to before the read, which fails it.
      final failed = _errorOf(refused);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      expect(await failed, isA<KeyTaken>());
      expect(ViewSettingsScope.read(context), _light(file));
      // Only the later change is saved.
      expect(store.waiting, 1);
      store.finishSave();
      await later;
      expect(store.settings.toJson(), _light(file).toJson());
    });

    testWidgets('only a key that another action has in the file: nothing is '
        'saved, and the file is shown (#315)', (tester) async {
      final file = _richFile.copyWith(
        keys: const KeyBindings().withKey(KeyAction.undo, _f5),
      );
      final store = _GatedStore(file);
      final context = await _host(tester, store);

      final refused = ViewSettingsScope.change(
        context,
        (s) => s.copyWith(
          keys: s.keys.withKey(KeyAction.searchInNote, _f5),
        ),
      );
      final failed = _errorOf(refused);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      expect(await failed, isA<KeyTaken>());
      await tester.pump();
      expect(ViewSettingsScope.read(context), file);
      expect(store.waiting, 0);
      expect(store.settings.toJson(), file.toJson());
    });

    testWidgets('another key set chosen replaces all keys, as it does after '
        'the read', (tester) async {
      final file = _richFile.copyWith(
        keys: const KeyBindings().withKey(KeyAction.undo, _f5),
      );
      final store = _GatedStore(file);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, _emacsKeys);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      final kept = _emacsKeys(_richFile);
      expect(ViewSettingsScope.read(context), kept);
      store.finishSave();
      await change;
      expect(store.settings.toJson(), kept.toJson());
    });

    testWidgets('fields that == leaves out, restored from the file, are '
        'kept by the next change', (tester) async {
      final file = ViewSettings.withDefaults().copyWith(
        lastSeenVersion: '0.3.0',
        lastUpdateCheckTime: DateTime.utc(2026, 11, 1),
      );
      final store = _GatedStore(file);
      final context = await _host(tester, store);

      final checked = DateTime.utc(2026, 11, 24, 8);
      final early = ViewSettingsScope.change(
        context,
        (s) => s.copyWith(lastUpdateCheckTime: checked),
      );
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave();
      await early;
      await tester.pump();
      expect(ViewSettingsScope.read(context).lastSeenVersion, '0.3.0');
      expect(ViewSettingsScope.read(context).lastUpdateCheckTime, checked);

      final later = ViewSettingsScope.change(context, _light);
      await tester.pump();
      store.finishSave();
      await later;
      expect(
        store.settings.toJson(),
        _light(file.copyWith(lastUpdateCheckTime: checked)).toJson(),
      );
    });

    testWidgets('the read changes only fields that == leaves out: they '
        'are kept by the next change', (tester) async {
      final checked = DateTime.utc(2026, 11, 1);
      final file = ViewSettings.withDefaults().copyWith(
        lastUpdateCheckTime: checked,
        lastSeenVersion: '0.3.0',
      );
      final store = _GatedStore(file);
      final context = await _host(tester, store);

      final early = ViewSettingsScope.change(context, _light);
      await tester.pump();
      // The settings read differ from those shown only in the update
      // check.
      store.finishLoad();
      await tester.pump();
      store.finishSave();
      await early;
      expect(store.settings.lastUpdateCheckTime, checked);

      await tester.pump();
      final later = ViewSettingsScope.change(context, _unjoined);
      await tester.pump();
      store.finishSave();
      await later;
      expect(
        store.settings.toJson(),
        _unjoined(_light(file)).toJson(),
      );
    });

    testWidgets("the read changes only fields that == leaves out: the "
        "View screen's switches keep them", (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final checked = DateTime.utc(2026, 11, 1);
      final file = ViewSettings.withDefaults().copyWith(
        lastUpdateCheckTime: checked,
        lastSeenVersion: '0.3.0',
      );
      final store = _GatedStore(file);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              ViewSettingsHost(store: store, child: child!),
          home: const ViewSettingsScreen(),
        ),
      );

      await tester.tap(find.text('Light'));
      await tester.pump();
      // The settings read differ from those shown only in the update
      // check.
      store.finishLoad();
      await tester.pump();
      store.finishSave();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('settings-join-lines')));
      await tester.pump();
      store.finishSave();
      await tester.pumpAndSettle();
      expect(
        store.settings.toJson(),
        _unjoined(_light(file)).toJson(),
      );
    });

    testWidgets("and the host gone before the read: it is still saved on "
        "the file's settings (#315)", (tester) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, _light);
      await tester.pumpWidget(const SizedBox());
      expect(store.waiting, 0);
      store.finishLoad();
      await tester.pump();
      store.finishSave();
      await change;
      expect(store.settings.toJson(), _light(_richFile).toJson());
    });

    testWidgets('a change made while it is saving is written last', (
      tester,
    ) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);

      final early = ViewSettingsScope.change(context, _light);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      final later = ViewSettingsScope.change(context, _neverScripts);
      await tester.pump();

      store.finishSave();
      await early;
      await tester.pump();
      store.finishSave();
      await later;
      final kept = _neverScripts(_light(_richFile));
      expect(store.settings.toJson(), kept.toJson());
      expect(ViewSettingsScope.read(context), kept);
    });

    testWidgets('an older save fails while a newer change is saving: '
        'the newer change is saved, with the older one', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, _light);
      final second = ViewSettingsScope.change(context, _unjoined);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(first, throwsA(isA<FileSystemException>()));
      await tester.pump();
      final both = _unjoined(_light(inFile));
      expect(ViewSettingsScope.read(context), both);

      store.finishSave();
      await second;
      await tester.pump();
      expect(ViewSettingsScope.read(context), both);
      expect(store.settings, both);
    });

    testWidgets('a failed save, then a newer change that is saved: the '
        'newer change is kept', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, _light);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(first, throwsA(isA<FileSystemException>()));
      await tester.pump();
      final second = ViewSettingsScope.change(context, _unjoined);
      await tester.pump();
      store.finishSave();
      await second;
      expect(ViewSettingsScope.read(context), _unjoined(inFile));
      expect(store.settings, _unjoined(inFile));
    });

    testWidgets('a failed save, then a newer change that fails too: back '
        'to the file', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, _light);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(first, throwsA(isA<FileSystemException>()));
      await tester.pump();
      final second = ViewSettingsScope.change(context, _unjoined);
      await tester.pump();
      expect(ViewSettingsScope.read(context), _unjoined(inFile));

      store.finishSave(fail: true);
      await expectLater(second, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), inFile);
    });

    testWidgets('a failed save, then a file that cannot be read: '
        'the defaults', (tester) async {
      final store = _GatedStore(inFile)..loadFails = true;
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, _light);
      await tester.pump();
      // The read error is caught: an uncaught one fails the test.
      store.finishLoad();
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(change, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), ViewSettings.withDefaults());
    });

    testWidgets('a saved change, a failed one, and a file that cannot be '
        'read: the saved change', (tester) async {
      final store = _GatedStore(inFile)..loadFails = true;
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, _light);
      final second = ViewSettingsScope.change(context, _unjoined);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave();
      await first;
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(second, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(
        ViewSettingsScope.read(context),
        _light(ViewSettings.withDefaults()),
      );
    });

    testWidgets('a read that throws an Error does not hold the save back', (
      tester,
    ) async {
      final store = _GatedStore(inFile)..loadError = StateError('broken');
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, _light);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      store.finishSave();
      await change;
      expect(store.settings, _light(ViewSettings.withDefaults()));
    });
  });

  group('a change as a function of the current settings (#315)', () {
    testWidgets('a screen that awaits something, then changes one field, '
        'keeps the fields changed meanwhile', (tester) async {
      final store = MemoryViewSettingsStore(_richFile);
      final context = await _host(tester, store);
      await tester.pump();

      // As a screen with a dialog: it has read the settings, waits, then
      // sets one field.
      final dialog = Completer<String>();
      Future<void> screen() async {
        final shown = ViewSettingsScope.read(context);
        expect(shown, _richFile);
        final folder = await dialog.future;
        await ViewSettingsScope.change(
          context,
          (s) => s.copyWith(imageFolder: folder),
        );
      }

      final done = screen();
      await ViewSettingsScope.change(context, _light);
      final checked = DateTime.utc(2026, 11, 27, 8);
      await ViewSettingsScope.change(
        context,
        (s) => s.copyWith(lastUpdateCheckTime: checked),
      );
      dialog.complete('pictures');
      await tester.pump();
      await done;

      final kept = _light(_richFile)
          .copyWith(imageFolder: 'pictures', lastUpdateCheckTime: checked);
      expect(ViewSettingsScope.read(context).toJson(), kept.toJson());
      expect(store.settings.toJson(), kept.toJson());
    });

    testWidgets("a dialog opened before the file is read and saved after it "
        "keeps the file's settings and the changes made meanwhile", (
      tester,
    ) async {
      final store = _GatedStore(_richFile);
      await _openFolderDialog(tester, store);
      await tester.enterText(
        find.byKey(const ValueKey('roam-directory-field')),
        '/emacs/roam',
      );
      store.finishLoad();
      await tester.pump();
      final meanwhile = ViewSettingsScope.change(
        tester.element(find.byType(SettingsScreen)),
        _light,
      );
      await tester.pump();
      store.finishSave();
      await meanwhile;

      await tester.tap(find.byKey(const ValueKey('roam-directory-save')));
      await tester.pumpAndSettle();
      store.finishSave();
      await tester.pumpAndSettle();
      expect(
        store.settings.toJson(),
        _light(_richFile)
            .copyWith(emacsRoamDirectory: '/emacs/roam')
            .toJson(),
      );
    });

    testWidgets("Save without an edit, in a dialog opened before the file is "
        "read, keeps the file's value", (tester) async {
      final file = _richFile.copyWith(emacsRoamDirectory: '/notes/roam');
      final store = _GatedStore(file);
      await _openFolderDialog(tester, store);
      store.finishLoad();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('roam-directory-save')));
      await tester.pumpAndSettle();
      expect(store.waiting, 0);
      expect(store.settings.toJson(), file.toJson());
    });

    testWidgets('"Not set", in a dialog opened before the file is read, '
        "clears the file's value", (tester) async {
      final file = _richFile.copyWith(emacsRoamDirectory: '/notes/roam');
      final store = _GatedStore(file);
      await _openFolderDialog(tester, store);
      store.finishLoad();
      await tester.pump();

      // The dialog shows nothing set, as it did when it opened.
      await tester.tap(find.byKey(const ValueKey('roam-directory-clear')));
      await tester.pumpAndSettle();
      store.finishSave();
      await tester.pumpAndSettle();
      expect(store.settings.toJson(), _richFile.toJson());
    });

    testWidgets('what the change throws is thrown, and nothing changes', (
      tester,
    ) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);
      store.finishLoad();
      await tester.pump();

      const taken = KeyTaken(_f5, KeyAction.undo);
      await expectLater(
        ViewSettingsScope.change(context, (_) => throw taken),
        throwsA(same(taken)),
      );
      await tester.pump();
      expect(ViewSettingsScope.read(context), _richFile);
      expect(store.waiting, 0);
    });

    testWidgets('a change made by a listener while one is applied is saved '
        'after it', (tester) async {
      final store = _GatedStore(_richFile);
      final context = await _host(tester, store);
      store.finishLoad();
      await tester.pump();
      final settings = context
          .getInheritedWidgetOfExactType<ViewSettingsScope>()!
          .notifier!;
      Future<void>? second;
      var changed = false;
      void again() {
        if (changed) return;
        changed = true;
        second = ViewSettingsScope.change(context, _neverScripts);
      }

      // The theme in the file is dark, so this notifies.
      settings.addListener(again);
      final first = ViewSettingsScope.change(context, _light);
      settings.removeListener(again);
      await tester.pump();
      store.finishSave();
      await first;
      expect(store.settings.toJson(), _light(_richFile).toJson());
      await tester.pump();
      store.finishSave();
      await second;
      expect(
        store.settings.toJson(),
        _neverScripts(_light(_richFile)).toJson(),
      );
    });

    testWidgets('another key set chosen after the read also replaces all '
        'keys', (tester) async {
      final file = _richFile.copyWith(
        keys: const KeyBindings().withKey(KeyAction.undo, _f5),
      );
      final store = _GatedStore(file);
      final context = await _host(tester, store);
      store.finishLoad();
      await tester.pump();

      // As the Keyboard screen chooses a set.
      final change = ViewSettingsScope.change(context, _emacsKeys);
      await tester.pump();
      store.finishSave();
      await change;
      expect(store.settings.keys, const KeyBindings(set: KeyScheme.emacs));
    });

    testWidgets('a change made while the failed save is undone is kept', (
      tester,
    ) async {
      const inFile = ViewSettings(theme: AppTheme.dark);
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);
      store.finishLoad();
      await tester.pump();
      final settings = context
          .getInheritedWidgetOfExactType<ViewSettingsScope>()!
          .notifier!;
      Future<void>? second;
      // Changes the settings again, once, from inside the notification
      // that undoes the failed save.
      void again() {
        if (second != null || settings.value != inFile) return;
        second = ViewSettingsScope.change(context, _unjoined);
      }

      settings.addListener(again);
      final first = ViewSettingsScope.change(context, _light);
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(first, throwsA(isA<FileSystemException>()));
      await tester.pump();
      settings.removeListener(again);
      expect(second, isNotNull);
      expect(ViewSettingsScope.read(context), _unjoined(inFile));

      store.finishSave();
      await second;
      expect(store.settings, _unjoined(inFile));
    });
  });

  test('the file store reads the file before a save called after the '
      'load writes it, also when finding the folder is slow (#310)', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('view-settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final direct = FileViewSettingsStore(
      path: '${dir.path}/view-settings.json',
    );
    await direct.save(_richFile);
    // Only the first lookup of the folder is slow.
    final slow = Completer<void>();
    var lookups = 0;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (++lookups == 1) await slow.future;
      return dir.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const store = FileViewSettingsStore();
    final chosen = ViewSettings.withDefaults().copyWith(theme: AppTheme.light);
    final loading = store.load();
    final saving = store.save(chosen);
    await pumpEventQueue();
    slow.complete();
    final loaded = await loading;
    await saving;

    expect(loaded.toJson(), _richFile.toJson());
    expect((await direct.load()).toJson(), chosen.toJson());
  });

  testWidgets('a failed save after the file is read goes back to the file', (
    tester,
  ) async {
    const inFile = ViewSettings(theme: AppTheme.dark);
    final store = _GatedStore(inFile);
    final context = await _host(tester, store);
    store.finishLoad();
    await tester.pump();
    expect(ViewSettingsScope.read(context), inFile);

    final change = ViewSettingsScope.change(context, _light);
    await tester.pump();
    store.finishSave(fail: true);
    await expectLater(change, throwsA(isA<FileSystemException>()));
    await tester.pump();
    expect(ViewSettingsScope.read(context), inFile);
  });
}

/// Changes as screens make them: each sets one thing.
ViewSettings _light(ViewSettings s) => s.copyWith(theme: AppTheme.light);

ViewSettings _unjoined(ViewSettings s) => s.copyWith(joinLines: false);

ViewSettings _neverScripts(ViewSettings s) =>
    s.copyWith(scripts: ScriptMode.never);

ViewSettings _emacsKeys(ViewSettings s) =>
    s.copyWith(keys: s.keys.withSet(KeyScheme.emacs));

/// What [change] fails with, or null; it listens at once.
Future<Object?> _errorOf(Future<void> change) => change.then<Object?>(
  (_) => null,
  onError: (Object error) => error,
);

const _f5 = KeyChord(LogicalKeyboardKey.f5);
const _f6 = KeyChord(LogicalKeyboardKey.f6);

/// A file with settings other than the defaults, also in fields that
/// [ViewSettings.==] leaves out.
final _richFile = ViewSettings(
  theme: AppTheme.dark,
  joinLines: false,
  emacsClient: 'emacsclient -n',
  lastUpdateCheckTime: DateTime.utc(2026, 11, 1),
  lastSeenVersion: '0.3.0',
);

/// Puts a [ViewSettingsHost] with [store] on screen and gives a context
/// below it.
Future<BuildContext> _host(WidgetTester tester, ViewSettingsStore store) async {
  late BuildContext below;
  await tester.pumpWidget(
    ViewSettingsHost(
      store: store,
      child: Builder(
        builder: (context) {
          below = context;
          return const SizedBox();
        },
      ),
    ),
  );
  return below;
}

/// Shows the Settings page with [store] and opens the dialog "Notes folder
/// on the computer with Emacs".
Future<void> _openFolderDialog(
  WidgetTester tester,
  ViewSettingsStore store,
) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          ViewSettingsHost(store: store, child: child!),
      home: const SettingsScreen(),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('settings-roam-directory')));
  await tester.pumpAndSettle();
}

/// A store whose load finishes only on [finishLoad], and whose saves
/// finish only on [finishSave], one at a time. The load gives the
/// settings as they were when it was called; with [loadFails] or
/// [loadError], it throws.
class _GatedStore extends MemoryViewSettingsStore {
  _GatedStore(super.settings);

  final _load = Completer<void>();
  final _saves = <Completer<void>>[];
  var loadFails = false;
  Error? loadError;

  /// The saves called and not finished.
  int get waiting => _saves.length;

  void finishLoad() => _load.complete();

  /// Finishes the oldest save; with [fail], it throws a
  /// [FileSystemException].
  void finishSave({bool fail = false}) => fail
      ? _saves.removeAt(0).completeError(const FileSystemException('full'))
      : _saves.removeAt(0).complete();

  @override
  Future<ViewSettings> load() async {
    final atStart = settings;
    await _load.future;
    if (loadFails) throw const FileSystemException('unreadable');
    if (loadError case final error?) throw error;
    return atStart;
  }

  @override
  Future<void> save(ViewSettings settings) async {
    final gate = Completer<void>();
    _saves.add(gate);
    await gate.future;
    await super.save(settings);
  }
}
