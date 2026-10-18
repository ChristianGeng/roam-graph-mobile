/// What differs on Linux, Windows and macOS (#116): notes open in Emacs,
/// links open in the desktop's browser, and shared text goes to the
/// clipboard.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// True on Linux, Windows and macOS. Read from [defaultTargetPlatform],
/// so widget tests, which run as Android, can set it.
bool get isDesktop => switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.macOS =>
        !kIsWeb,
      _ => false,
    };

bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

/// The app notes open in outside this one: Emacs on the desktop, Orgro on
/// Android.
String get noteAppName => isDesktop ? 'Emacs' : 'Orgro';

/// Runs a program; tests replace it. Throws [ProcessException] when the
/// program is not there.
typedef ProcessStarter = Future<void> Function(
    String executable, List<String> arguments);

Future<void> startDetached(String executable, List<String> arguments) async {
  // No shell: a file name or address with `&` or spaces stays one
  // argument.
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}

/// The default `emacsclient` of each system: on Windows the one without a
/// console window.
String get defaultEmacsClient =>
    _isWindows ? 'emacsclientw.exe' : 'emacsclient';

/// The arguments that open [file] at [line] in the running Emacs, without
/// waiting (`-n`). Without a running Emacs server, `emacs` itself opens it
/// (`-a emacs`).
List<String> emacsArguments(String file, int line) =>
    ['-n', '-a', 'emacs', '+${line < 1 ? 1 : line}', file];

/// Opens [uri] in the desktop's browser, or mail or phone app: `xdg-open`,
/// `open`, or Windows' URL handler. False when that cannot be started.
Future<bool> openUrlOnDesktop(Uri uri,
    {ProcessStarter start = startDetached}) async {
  try {
    if (_isWindows) {
      // Windows' own handler for addresses; not `start`, which is a command
      // of cmd, where `&` in an address would end it.
      await start('rundll32', ['url.dll,FileProtocolHandler', uri.toString()]);
    } else {
      await start(defaultTargetPlatform == TargetPlatform.macOS ? 'open' : 'xdg-open',
          [uri.toString()]);
    }
    return true;
  } on ProcessException {
    return false;
  }
}

/// Sharing on the desktop: the text goes to the clipboard, to paste into
/// an AI app (#41).
Future<void> copyTextOut(String text, {String? subject}) =>
    Clipboard.setData(ClipboardData(text: text));
