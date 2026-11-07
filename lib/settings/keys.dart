/// The desktop's keys (#256): one table of actions, each with a default
/// key in the default set and in the "Emacs" set, and the keys the user
/// changed. Every screen reads its keys from here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;

/// What a key can do, in the order Settings → Keyboard lists them.
enum KeyAction {
  chatSend('Send the message',
      'In the AI chat, Edit with AI and Create image'),
  submit('Send or save',
      'In the message fields, and Save or Review in the edit screens'),
  cancel('Leave the field, close the search',
      'Gives the focus back to the page'),
  searchInNote('Search in the note', 'Opens the search bar of the note'),
  newFromClipboard('New note from clipboard', 'In the graph'),
  promote('Promote the heading', 'The current heading in the note view'),
  demote('Demote the heading', 'The current heading in the note view'),
  moveUp('Move the heading up', 'The current heading in the note view'),
  moveDown('Move the heading down', 'The current heading in the note view'),
  todoPrevious('Previous TODO state', 'The current heading in the note view'),
  todoNext('Next TODO state', 'The current heading in the note view'),
  deleteHeading('Delete the heading', 'The current heading in the note view'),
  undo('Undo the last quick edit', 'In the note view');

  const KeyAction(this.label, this.where);
  final String label;

  /// Where the key works.
  final String where;
}

/// One key press: a key and the modifiers held with it, exactly.
@immutable
class KeyChord {
  const KeyChord(this.key,
      {this.control = false,
      this.shift = false,
      this.alt = false,
      this.meta = false});

  /// [key] with Ctrl, or with Cmd on macOS.
  factory KeyChord.primary(LogicalKeyboardKey key, {bool shift = false}) =>
      defaultTargetPlatform == TargetPlatform.macOS
          ? KeyChord(key, meta: true, shift: shift)
          : KeyChord(key, control: true, shift: shift);

  final LogicalKeyboardKey key;
  final bool control, shift, alt, meta;

  SingleActivator get activator => SingleActivator(key,
      control: control, shift: shift, alt: alt, meta: meta);

  /// Whether [event] is this chord. Enter also matches the keypad's
  /// Enter.
  bool accepts(KeyEvent event, [HardwareKeyboard? keyboard]) {
    final keys = keyboard ?? HardwareKeyboard.instance;
    if (activator.accepts(event, keys)) return true;
    return key == LogicalKeyboardKey.enter &&
        SingleActivator(LogicalKeyboardKey.numpadEnter,
                control: control, shift: shift, alt: alt, meta: meta)
            .accepts(event, keys);
  }

  /// The chord as the menus and Settings show it, such as "Ctrl+Enter".
  String get label {
    final macOS = defaultTargetPlatform == TargetPlatform.macOS;
    return [
      if (control) 'Ctrl',
      if (meta) macOS ? 'Cmd' : 'Super',
      if (alt) macOS ? 'Option' : 'Alt',
      if (shift) 'Shift',
      keyName(key),
    ].join('+');
  }

  /// A key's short name: "Left" for the arrow key, "Esc", "V".
  static String keyName(LogicalKeyboardKey key) =>
      _names[key] ?? (key.keyLabel.isEmpty ? key.debugName ?? '?' : key.keyLabel);

  static final _names = {
    LogicalKeyboardKey.arrowLeft: 'Left',
    LogicalKeyboardKey.arrowRight: 'Right',
    LogicalKeyboardKey.arrowUp: 'Up',
    LogicalKeyboardKey.arrowDown: 'Down',
    LogicalKeyboardKey.escape: 'Esc',
    LogicalKeyboardKey.numpadEnter: 'Enter',
  };

  /// The keys that are only modifiers, which make no chord alone.
  static final modifiers = {
    ...LogicalKeyboardKey.expandSynonyms({
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.shift,
      LogicalKeyboardKey.alt,
      LogicalKeyboardKey.meta,
    }),
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
    LogicalKeyboardKey.altGraph,
  };

  /// The chord of [event] with the modifiers held now; null for a
  /// modifier alone.
  static KeyChord? of(KeyEvent event, [HardwareKeyboard? keyboard]) {
    final keys = keyboard ?? HardwareKeyboard.instance;
    if (modifiers.contains(event.logicalKey)) return null;
    return KeyChord(event.logicalKey,
        control: keys.isControlPressed,
        shift: keys.isShiftPressed,
        alt: keys.isAltPressed,
        meta: keys.isMetaPressed);
  }

  Map<String, Object?> toJson() => {
        'key': key.keyId,
        if (control) 'ctrl': true,
        if (shift) 'shift': true,
        if (alt) 'alt': true,
        if (meta) 'meta': true,
      };

  /// The chord in [json], or null when it is not one.
  static KeyChord? fromJson(Object? json) {
    if (json is! Map || json['key'] is! int) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(json['key'] as int) ??
        LogicalKeyboardKey(json['key'] as int);
    return KeyChord(key,
        control: json['ctrl'] == true,
        shift: json['shift'] == true,
        alt: json['alt'] == true,
        meta: json['meta'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.key == key &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, control, shift, alt, meta);

  @override
  String toString() => label;
}

/// The default keys of each set; the user picks one, then may change
/// single keys.
enum KeyScheme {
  standard('Default', 'Enter sends, Ctrl+F searches, Esc leaves a field'),
  emacs('Emacs', 'Ctrl+Enter sends, Ctrl+S searches, Ctrl+G cancels');

  const KeyScheme(this.label, this.description);
  final String label;
  final String description;

  /// The key of [action] in this set; null when the set has none.
  KeyChord? defaultOf(KeyAction action) {
    final standard = _standard(action);
    if (this == KeyScheme.standard) return standard;
    return switch (action) {
      // Enter makes a new line, as in an Emacs buffer.
      KeyAction.chatSend => null,
      KeyAction.submit =>
        const KeyChord(LogicalKeyboardKey.enter, control: true),
      KeyAction.cancel => const KeyChord(LogicalKeyboardKey.keyG, control: true),
      KeyAction.searchInNote =>
        const KeyChord(LogicalKeyboardKey.keyS, control: true),
      _ => standard,
    };
  }

  static KeyChord _standard(KeyAction action) => switch (action) {
        KeyAction.chatSend => const KeyChord(LogicalKeyboardKey.enter),
        KeyAction.submit => KeyChord.primary(LogicalKeyboardKey.enter),
        KeyAction.cancel => const KeyChord(LogicalKeyboardKey.escape),
        KeyAction.searchInNote => KeyChord.primary(LogicalKeyboardKey.keyF),
        KeyAction.newFromClipboard =>
          KeyChord.primary(LogicalKeyboardKey.keyV, shift: true),
        KeyAction.promote => const KeyChord(LogicalKeyboardKey.arrowLeft,
            alt: true, shift: true),
        KeyAction.demote => const KeyChord(LogicalKeyboardKey.arrowRight,
            alt: true, shift: true),
        KeyAction.moveUp =>
          const KeyChord(LogicalKeyboardKey.arrowUp, alt: true),
        KeyAction.moveDown =>
          const KeyChord(LogicalKeyboardKey.arrowDown, alt: true),
        KeyAction.todoPrevious =>
          const KeyChord(LogicalKeyboardKey.arrowLeft, shift: true),
        KeyAction.todoNext =>
          const KeyChord(LogicalKeyboardKey.arrowRight, shift: true),
        KeyAction.deleteHeading => const KeyChord(LogicalKeyboardKey.delete),
        KeyAction.undo => KeyChord.primary(LogicalKeyboardKey.keyZ),
      };
}

/// The keys in use: a [KeyScheme] and the keys changed from it. Stored in
/// `view-settings.json` as the set and only the changed keys.
@immutable
class KeyBindings {
  const KeyBindings({this.set = KeyScheme.standard, this.changed = const {}});

  final KeyScheme set;

  /// The keys that differ from [set]; null for an action without a key.
  final Map<KeyAction, KeyChord?> changed;

  /// The key of [action] now; null when it has none.
  KeyChord? of(KeyAction action) =>
      changed.containsKey(action) ? changed[action] : set.defaultOf(action);

  /// [of] as text; "No key" without one.
  String labelOf(KeyAction action) => of(action)?.label ?? 'No key';

  bool isChanged(KeyAction action) => changed.containsKey(action);

  /// The other action that has [chord], if any.
  KeyAction? usedBy(KeyChord chord, {KeyAction? except}) => KeyAction.values
      .where((a) => a != except && of(a) == chord)
      .firstOrNull;

  /// These keys with [chord] for [action] (null: no key). Throws
  /// [KeyTaken] when another action has [chord]; a chord equal to the
  /// set's default is not stored.
  KeyBindings withKey(KeyAction action, KeyChord? chord) {
    if (chord != null) {
      if (usedBy(chord, except: action) case final other?) {
        throw KeyTaken(chord, other);
      }
    }
    final next = {...changed}..remove(action);
    if (chord != set.defaultOf(action)) next[action] = chord;
    return KeyBindings(set: set, changed: next);
  }

  /// These keys with [action] back to the set's default. Throws
  /// [KeyTaken] when a changed key of another action has that default.
  KeyBindings reset(KeyAction action) => withKey(action, set.defaultOf(action));

  /// The defaults of [set], without changed keys.
  KeyBindings withSet(KeyScheme set) => KeyBindings(set: set);

  Map<String, Object?> toJson() => {
        'set': set.name,
        'changed': {
          for (final MapEntry(:key, :value) in changed.entries)
            key.name: value?.toJson(),
        },
      };

  /// The keys in [json]; unknown actions and keys that are not chords are
  /// left out.
  factory KeyBindings.fromJson(Object? json) {
    if (json is! Map) return const KeyBindings();
    final set = KeyScheme.values
            .where((s) => s.name == json['set'])
            .firstOrNull ??
        KeyScheme.standard;
    final read = <KeyAction, KeyChord?>{};
    final changed = json['changed'];
    if (changed is Map) {
      for (final MapEntry(:key, :value) in changed.entries) {
        final action =
            KeyAction.values.where((a) => a.name == key).firstOrNull;
        if (action == null) continue;
        final chord = KeyChord.fromJson(value);
        if (value != null && chord == null) continue;
        if (chord != set.defaultOf(action)) read[action] = chord;
      }
    }
    final keys = KeyBindings(set: set, changed: read);
    // A file edited by hand may give two actions one key: both go back
    // to the set's defaults.
    final twice = {
      for (final action in read.keys)
        if (keys.of(action) case final chord?
            when keys.usedBy(chord, except: action) != null)
          action,
    };
    if (twice.isEmpty) return keys;
    return KeyBindings(
        set: set, changed: {...read}..removeWhere((a, _) => twice.contains(a)));
  }

  @override
  bool operator ==(Object other) =>
      other is KeyBindings &&
      other.set == set &&
      mapEquals(other.changed, changed);

  @override
  int get hashCode => Object.hash(
      set,
      Object.hashAllUnordered(
          [for (final e in changed.entries) Object.hash(e.key, e.value)]));
}

/// Thrown when a key is set that another action has.
class KeyTaken implements Exception {
  const KeyTaken(this.chord, this.action);
  final KeyChord chord;
  final KeyAction action;

  String get message => '${chord.label} is already "${action.label}".';

  @override
  String toString() => message;
}
