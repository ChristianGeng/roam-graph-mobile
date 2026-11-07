/// The keys of a text field that ends in a button (#256): on the desktop,
/// "Send" or "Save" and "Leave the field" from the key table. On Android
/// and iOS the field is left as it is: Enter makes a new line.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform/desktop.dart';
import 'keys.dart';
import 'view_settings.dart';

/// Gives [child], a text field or a page of them, the keys of the table.
/// [onSubmit] runs on [KeyAction.submit], and with [enterSends] also on
/// [KeyAction.chatSend]; null while there is nothing to send, then the
/// key does nothing. [onCancel] runs on [KeyAction.cancel].
class FieldKeys extends StatelessWidget {
  const FieldKeys({
    super.key,
    this.controller,
    required this.onSubmit,
    this.enterSends = false,
    this.onCancel,
    required this.child,
  });

  /// The field's text. While an input method composes in it, or in the
  /// focused field of a page without [controller] (a dead key, Japanese),
  /// the keys go to the field, so the Enter that ends the composition
  /// sends nothing.
  final TextEditingController? controller;

  final VoidCallback? onSubmit;

  /// Whether [KeyAction.chatSend] (Enter by default) sends: in message
  /// fields, not in fields that hold the text of a note.
  final bool enterSends;

  final VoidCallback? onCancel;

  final Widget child;

  /// Whether an input method composes in [controller], or, on a page of
  /// fields, in the field that has the focus.
  bool _composing() {
    if (controller?.value.isComposingRangeValid ?? false) return true;
    final field = primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    return field?.textEditingValue.isComposingRangeValid ?? false;
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return child;
    final keys = ViewSettingsScope.of(context).keys;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (_composing()) return KeyEventResult.ignored;
        bool pressed(KeyAction action) =>
            keys.of(action)?.accepts(event) ?? false;
        if (pressed(KeyAction.submit) ||
            (enterSends && pressed(KeyAction.chatSend))) {
          // Also while sending is not possible: the key sends, it does not
          // make a new line then.
          if (event is KeyDownEvent) onSubmit?.call();
          return KeyEventResult.handled;
        }
        if (onCancel != null && pressed(KeyAction.cancel)) {
          onCancel!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
