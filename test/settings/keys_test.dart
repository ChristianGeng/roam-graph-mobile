import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/settings/keys.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

const ctrlEnter = KeyChord(LogicalKeyboardKey.enter, control: true);
const ctrlJ = KeyChord(LogicalKeyboardKey.keyJ, control: true);

void main() {
  group('the key table (#256)', () {
    for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
      test('every action has a default key, no key twice, on ${platform.name}',
          () {
        debugDefaultTargetPlatformOverride = platform;
        try {
          const keys = KeyBindings();
          for (final action in KeyAction.values) {
            final chord = keys.of(action);
            expect(chord, isNotNull, reason: action.name);
            expect(keys.usedBy(chord!, except: action), isNull,
                reason: action.name);
          }
          const emacs = KeyBindings(set: KeyScheme.emacs);
          for (final action in KeyAction.values) {
            if (emacs.of(action) case final chord?) {
              expect(emacs.usedBy(chord, except: action), isNull,
                  reason: action.name);
            }
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    test('the defaults are the keys the app had, and Enter sends', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        const keys = KeyBindings();
        expect(keys.labelOf(KeyAction.chatSend), 'Enter');
        expect(keys.labelOf(KeyAction.submit), 'Ctrl+Enter');
        expect(keys.labelOf(KeyAction.cancel), 'Esc');
        expect(keys.labelOf(KeyAction.searchInNote), 'Ctrl+F');
        expect(keys.labelOf(KeyAction.newFromClipboard), 'Ctrl+Shift+V');
        expect(keys.labelOf(KeyAction.promote), 'Alt+Shift+Left');
        expect(keys.labelOf(KeyAction.demote), 'Alt+Shift+Right');
        expect(keys.labelOf(KeyAction.moveUp), 'Alt+Up');
        expect(keys.labelOf(KeyAction.moveDown), 'Alt+Down');
        expect(keys.labelOf(KeyAction.todoPrevious), 'Shift+Left');
        expect(keys.labelOf(KeyAction.todoNext), 'Shift+Right');
        expect(keys.labelOf(KeyAction.deleteHeading), 'Delete');
        expect(keys.labelOf(KeyAction.undo), 'Ctrl+Z');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('macOS uses Cmd where the others use Ctrl', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        const keys = KeyBindings();
        expect(keys.labelOf(KeyAction.submit), 'Cmd+Enter');
        expect(keys.labelOf(KeyAction.searchInNote), 'Cmd+F');
        expect(keys.labelOf(KeyAction.newFromClipboard), 'Cmd+Shift+V');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('the Emacs set', () {
      const keys = KeyBindings(set: KeyScheme.emacs);
      expect(keys.of(KeyAction.chatSend), isNull);
      expect(keys.of(KeyAction.submit), ctrlEnter);
      expect(keys.labelOf(KeyAction.cancel), 'Ctrl+G');
      expect(keys.labelOf(KeyAction.searchInNote), 'Ctrl+S');
      // The heading keys are those of Org in both sets.
      expect(keys.of(KeyAction.promote),
          const KeyBindings().of(KeyAction.promote));
    });

    test('a key another action has is refused, with that action', () {
      const keys = KeyBindings();
      expect(
        () => keys.withKey(KeyAction.searchInNote, ctrlEnter),
        throwsA(isA<KeyTaken>()
            .having((e) => e.action, 'action', KeyAction.submit)
            .having((e) => e.message, 'message',
                'Ctrl+Enter is already "Send or save".')),
      );
      // An action may keep its own key.
      expect(keys.withKey(KeyAction.submit, ctrlEnter), keys);
    });

    test('a changed key is stored, read back, and Reset removes it', () {
      final keys = const KeyBindings().withKey(KeyAction.searchInNote, ctrlJ);
      expect(keys.of(KeyAction.searchInNote), ctrlJ);
      expect(keys.changed.keys, [KeyAction.searchInNote]);
      final json = keys.toJson();
      // Only the keys that differ from the set are stored.
      expect(json['changed'], {
        'searchInNote': {'key': LogicalKeyboardKey.keyJ.keyId, 'ctrl': true},
      });
      final read = KeyBindings.fromJson(json);
      expect(read, keys);
      expect(read.of(KeyAction.searchInNote), ctrlJ);

      final reset = read.reset(KeyAction.searchInNote);
      expect(reset.changed, isEmpty);
      expect(reset.toJson()['changed'], isEmpty);
      expect(reset, const KeyBindings());
    });

    test('the keypad Enter is Enter, also in a file edited by hand', () {
      final read = KeyBindings.fromJson({
        'set': 'standard',
        'changed': {
          'searchInNote': {'key': LogicalKeyboardKey.numpadEnter.keyId},
        },
      });
      // Enter is "Send the message": the duplicate goes.
      expect(read.changed, isEmpty);
      expect(
          KeyChord.fromJson({'key': LogicalKeyboardKey.numpadEnter.keyId}),
          const KeyChord(LogicalKeyboardKey.enter));
    });

    testWidgets('a captured keypad Enter is Enter', (tester) async {
      KeyChord? captured;
      await tester.pumpWidget(Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) captured = KeyChord.of(event);
          return KeyEventResult.handled;
        },
        child: const SizedBox(),
      ));
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      expect(captured, const KeyChord(LogicalKeyboardKey.enter));
      expect(const KeyBindings().usedBy(captured!), KeyAction.chatSend);
    });

    test('setting the default key again stores nothing', () {
      final keys = const KeyBindings()
          .withKey(KeyAction.cancel, const KeyChord(LogicalKeyboardKey.escape));
      expect(keys.changed, isEmpty);
    });

    test('an action without a key is stored as such', () {
      final keys = const KeyBindings().withKey(KeyAction.chatSend, null);
      expect(keys.of(KeyAction.chatSend), isNull);
      expect(keys.labelOf(KeyAction.chatSend), 'No key');
      expect(KeyBindings.fromJson(keys.toJson()).of(KeyAction.chatSend),
          isNull);
      // Its old key is free now.
      final again = keys.withKey(
          KeyAction.submit, const KeyChord(LogicalKeyboardKey.enter));
      expect(again.labelOf(KeyAction.submit), 'Enter');
    });

    test('choosing a set drops the changed keys', () {
      final keys = const KeyBindings().withKey(KeyAction.searchInNote, ctrlJ);
      final emacs = keys.withSet(KeyScheme.emacs);
      expect(emacs.changed, isEmpty);
      expect(emacs.set, KeyScheme.emacs);
    });

    test('a file edited by hand with one key twice gets the defaults back',
        () {
      final keys = KeyBindings.fromJson({
        'set': 'standard',
        'changed': {
          'searchInNote': {'key': LogicalKeyboardKey.keyZ.keyId, 'ctrl': true},
          'promote': 'not a key',
          'noSuchAction': {'key': 1},
        },
      });
      expect(keys.changed, isEmpty);
    });

    test('the keys go through view-settings.json', () async {
      final dir = Directory.systemTemp.createTempSync('keys-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FileViewSettingsStore(path: '${dir.path}/view.json');
      final keys = const KeyBindings(set: KeyScheme.emacs)
          .withKey(KeyAction.searchInNote, ctrlJ);
      await store.save(ViewSettings.withDefaults().copyWith(keys: keys));
      final loaded = await store.load();
      expect(loaded.keys, keys);
      expect(loaded.keys.of(KeyAction.searchInNote), ctrlJ);
      expect(loaded.keys.labelOf(KeyAction.cancel), 'Ctrl+G');

      await store.save(loaded.copyWith(
          keys: loaded.keys.reset(KeyAction.searchInNote)));
      expect((await store.load()).keys.changed, isEmpty);
    });

    test('older settings files without keys read as the defaults', () {
      expect(ViewSettings.fromJson(const {}).keys, const KeyBindings());
    });
  });
}
