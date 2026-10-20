/// The screen stays on while the AI works (#131): a locked screen can cut
/// a request in the middle of an agent's task. Android only; elsewhere
/// nothing happens.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('roam_graph/screen');

/// How many pieces of work want the screen on now.
int _holders = 0;

/// Runs [work] with the screen kept on, and lets it lock again afterwards
/// unless other work still runs.
Future<T> whileScreenOn<T>(Future<T> Function() work) async {
  if (_holders++ == 0) await _set(true);
  try {
    return await work();
  } finally {
    if (--_holders == 0) await _set(false);
  }
}

Future<void> _set(bool on) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _channel.invokeMethod<void>('keepScreenOn', {'on': on});
  } on PlatformException {
    // The screen may lock; the request is tried again (#131).
  } on MissingPluginException {
    // Tests, and builds without the channel.
  }
}
