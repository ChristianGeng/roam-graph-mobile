import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/settings/field_keys.dart';

/// The keys of the fields that end in a button (#256): capture, Append,
/// Edit text and Title and tags give `FieldKeys` only `onSubmit`; Edit
/// with AI and Create image also `enterSends`, as the chat does (see
/// chat_screen_test.dart).
void main() {
  late int submitted;
  late TextEditingController text;

  Future<void> pump(WidgetTester tester,
      {bool enterSends = false,
      bool canSubmit = true,
      bool withController = true}) async {
    submitted = 0;
    text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FieldKeys(
          controller: withController ? text : null,
          enterSends: enterSends,
          onSubmit: canSubmit ? () => submitted++ : null,
          child: TextField(
              key: const ValueKey('field'), controller: text, maxLines: null),
        ),
      ),
    ));
    await tester.showKeyboard(find.byKey(const ValueKey('field')));
    await tester.enterText(find.byKey(const ValueKey('field')), 'Some text');
    await tester.pump();
  }

  Future<bool> press(WidgetTester tester, LogicalKeyboardKey key,
      {LogicalKeyboardKey? held}) async {
    if (held != null) await tester.sendKeyDownEvent(held);
    final handled = await tester.sendKeyEvent(key);
    if (held != null) await tester.sendKeyUpEvent(held);
    await tester.pump();
    return handled;
  }

  void onLinux(String name, Future<void> Function(WidgetTester) body) {
    testWidgets('linux: $name', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  onLinux('in a note text field Ctrl+Enter saves; Enter is a new line',
      (tester) async {
    await pump(tester);
    expect(await press(tester, LogicalKeyboardKey.enter), isFalse);
    expect(submitted, 0);
    await press(tester, LogicalKeyboardKey.enter,
        held: LogicalKeyboardKey.controlLeft);
    expect(submitted, 1);
  });

  onLinux('in a message field Enter sends too', (tester) async {
    await pump(tester, enterSends: true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(submitted, 1);
    expect(
        await press(tester, LogicalKeyboardKey.enter,
            held: LogicalKeyboardKey.shiftLeft),
        isFalse);
    expect(submitted, 1);
  });

  onLinux('while the button is off the key does nothing, and makes no line',
      (tester) async {
    await pump(tester, canSubmit: false);
    expect(
        await press(tester, LogicalKeyboardKey.enter,
            held: LogicalKeyboardKey.controlLeft),
        isTrue);
    expect(submitted, 0);
  });

  for (final withController in [true, false]) {
    onLinux(
        'while an input method composes, the key goes to the field'
        '${withController ? '' : ' (a page without controller)'}',
        (tester) async {
      await pump(tester, enterSends: true, withController: withController);
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ka',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ));
      await tester.pump();
      expect(await press(tester, LogicalKeyboardKey.enter), isFalse);
      expect(
          await press(tester, LogicalKeyboardKey.enter,
              held: LogicalKeyboardKey.controlLeft),
          isFalse);
      expect(submitted, 0);
    });
  }

  testWidgets('android: no key saves', (tester) async {
    await pump(tester, enterSends: true);
    expect(await press(tester, LogicalKeyboardKey.enter), isFalse);
    expect(
        await press(tester, LogicalKeyboardKey.enter,
            held: LogicalKeyboardKey.controlLeft),
        isFalse);
    expect(submitted, 0);
  });
}
