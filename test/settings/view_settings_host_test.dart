import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

void main() {
  group('a change made before the file is read (#296)', () {
    const inFile = ViewSettings(theme: AppTheme.dark);
    const chosen = ViewSettings(theme: AppTheme.light);
    const newer = ViewSettings(theme: AppTheme.light, joinLines: false);

    testWidgets('whose save fails: the file is used once it is read', (
      tester,
    ) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, chosen);
      await tester.pump();
      expect(ViewSettingsScope.read(context), chosen);
      store.finishSave(fail: true);
      await expectLater(change, throwsA(isA<FileSystemException>()));
      await tester.pump();

      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), inFile);
    });

    testWidgets('whose save succeeds: the change is kept', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, chosen);
      await tester.pump();
      store.finishSave();
      await change;

      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), chosen);
      expect(store.settings, chosen);

      // The file read is older than the save: a later failed save goes
      // back to the saved change, not to it.
      final failing = ViewSettingsScope.change(
        context,
        const ViewSettings(theme: AppTheme.system),
      );
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(failing, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), chosen);
    });

    testWidgets('an older save fails while a newer change is saving: '
        'the newer change is kept', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, chosen);
      final second = ViewSettingsScope.change(context, newer);
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(first, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), newer);

      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), newer);
      store.finishSave();
      await second;
      await tester.pump();
      expect(ViewSettingsScope.read(context), newer);
      expect(store.settings, newer);
    });

    testWidgets('a failed save, then a newer change that fails after the '
        'file is read: back to the file', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, chosen);
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(first, throwsA(isA<FileSystemException>()));
      final second = ViewSettingsScope.change(context, newer);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), newer);

      store.finishSave(fail: true);
      await expectLater(second, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), inFile);
    });

    testWidgets('a saved change, then a failed one: the saved change, '
        'also after the file is read', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, chosen);
      await tester.pump();
      store.finishSave();
      await first;
      final second = ViewSettingsScope.change(context, newer);
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(second, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), chosen);

      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), chosen);
    });

    testWidgets('a failed save, then a file that cannot be read: '
        'the defaults', (tester) async {
      final store = _GatedStore(inFile)..loadFails = true;
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, chosen);
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(change, throwsA(isA<FileSystemException>()));
      await tester.pump();

      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), ViewSettings.withDefaults());
    });

    testWidgets('still saving when the file is read, then failing: '
        'back to the file', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final change = ViewSettingsScope.change(context, chosen);
      await tester.pump();
      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), chosen);

      store.finishSave(fail: true);
      await expectLater(change, throwsA(isA<FileSystemException>()));
      await tester.pump();
      expect(ViewSettingsScope.read(context), inFile);
    });

    testWidgets('a failed save, then a newer change still saving: '
        'the newer change is kept', (tester) async {
      final store = _GatedStore(inFile);
      final context = await _host(tester, store);

      final first = ViewSettingsScope.change(context, chosen);
      await tester.pump();
      store.finishSave(fail: true);
      await expectLater(first, throwsA(isA<FileSystemException>()));
      final second = ViewSettingsScope.change(context, newer);
      await tester.pump();

      store.finishLoad();
      await tester.pump();
      expect(ViewSettingsScope.read(context), newer);
      store.finishSave();
      await second;
      expect(ViewSettingsScope.read(context), newer);
    });
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

    final change = ViewSettingsScope.change(
      context,
      const ViewSettings(theme: AppTheme.light),
    );
    await tester.pump();
    store.finishSave(fail: true);
    await expectLater(change, throwsA(isA<FileSystemException>()));
    await tester.pump();
    expect(ViewSettingsScope.read(context), inFile);
  });
}

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

/// A store whose load finishes only on [finishLoad], and whose saves
/// finish only on [finishSave], one at a time. The load gives the
/// settings as they were when it was called, as a file read at the start
/// would; with [loadFails], it throws.
class _GatedStore extends MemoryViewSettingsStore {
  _GatedStore(super.settings);

  final _load = Completer<void>();
  final _saves = <Completer<void>>[];
  var loadFails = false;

  void finishLoad() => _load.complete();

  /// Finishes the oldest save; with [fail], it throws.
  void finishSave({bool fail = false}) => fail
      ? _saves.removeAt(0).completeError(const FileSystemException('full'))
      : _saves.removeAt(0).complete();

  @override
  Future<ViewSettings> load() async {
    final atStart = settings;
    await _load.future;
    if (loadFails) throw const FileSystemException('unreadable');
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
