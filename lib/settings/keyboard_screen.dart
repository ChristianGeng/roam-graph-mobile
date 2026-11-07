/// Settings → Keyboard (#256), on the desktop: the set of default keys,
/// and each action with its key, to change or reset.
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../platform/error_text.dart';
import 'keys.dart';
import 'view_settings.dart';

class KeyboardSettingsScreen extends StatelessWidget {
  const KeyboardSettingsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const KeyboardSettingsScreen()),
      );

  Future<void> _save(BuildContext context, KeyBindings keys) async {
    final settings = ViewSettingsScope.read(context);
    try {
      await ViewSettingsScope.change(context, settings.copyWith(keys: keys));
    } on Exception catch (e) {
      if (context.mounted) {
        showErrorSnackBar(
            ScaffoldMessenger.of(context), 'Could not save the setting: $e');
      }
    }
  }

  /// Sets [keys] from [change], or says why not.
  Future<void> _try(BuildContext context, KeyBindings Function() change) async {
    final KeyBindings next;
    try {
      next = change();
    } on KeyTaken catch (taken) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(taken.message)));
      return;
    }
    await _save(context, next);
  }

  Future<void> _change(
      BuildContext context, KeyBindings keys, KeyAction action) async {
    final chosen = await showDialog<({KeyChord? chord})>(
      context: context,
      builder: (_) => _KeyDialog(keys: keys, action: action),
    );
    if (chosen == null || !context.mounted) return;
    await _try(context, () => keys.withKey(action, chosen.chord));
  }

  @override
  Widget build(BuildContext context) {
    final keys = ViewSettingsScope.of(context).keys;
    return Scaffold(
      appBar: AppBar(title: const Text('Keyboard')),
      body: ListView(
        children: [
          const ListTile(
            title: Text('Default keys'),
            subtitle: Text('Choosing a set undoes the keys changed below.'),
          ),
          RadioGroup<KeyScheme>(
            groupValue: keys.set,
            onChanged: (set) {
              if (set != null && set != keys.set) {
                _save(context, keys.withSet(set));
              }
            },
            child: Column(
              children: [
                for (final set in KeyScheme.values)
                  RadioListTile<KeyScheme>(
                    key: ValueKey('key-set-${set.name}'),
                    value: set,
                    title: Text(set.label),
                    subtitle: Text(set.description),
                  ),
              ],
            ),
          ),
          const Divider(),
          const ListTile(
            title: Text('Keys'),
            subtitle: Text('Tap an action, then press its new key. Shift+Enter '
                'always makes a new line in a field.'),
          ),
          for (final action in KeyAction.values)
            ListTile(
              key: ValueKey('key-${action.name}'),
              title: Text(action.label),
              subtitle: Text(action.where),
              onTap: () => _change(context, keys, action),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Text(keys.labelOf(action),
                      key: ValueKey('key-label-${action.name}'),
                      style: TextStyle(
                          fontWeight: keys.isChanged(action)
                              ? FontWeight.bold
                              : null)),
                  TextButton(
                    key: ValueKey('key-reset-${action.name}'),
                    onPressed: keys.isChanged(action)
                        ? () => _try(context, () => keys.reset(action))
                        : null,
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Waits for one key press and gives it back, or "No key"; a key that
/// another action has is refused here, with that action's name.
class _KeyDialog extends StatefulWidget {
  const _KeyDialog({required this.keys, required this.action});

  final KeyBindings keys;
  final KeyAction action;

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  String? _refused;

  KeyEventResult _pressed(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final chord = KeyChord.of(event);
    if (chord == null) return KeyEventResult.handled;
    if (widget.keys.usedBy(chord, except: widget.action) case final other?) {
      setState(() => _refused = KeyTaken(chord, other).message);
      return KeyEventResult.handled;
    }
    Navigator.pop(context, (chord: chord));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.action.label),
        content: Focus(
          autofocus: true,
          onKeyEvent: _pressed,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Press the new key. Now: ${widget.keys.labelOf(widget.action)}.'),
              if (_refused case final refused?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(refused,
                      key: const ValueKey('key-refused'),
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('key-none'),
            onPressed: () => Navigator.pop(context, (chord: null)),
            child: const Text('No key'),
          ),
        ],
      );
}
