/// What keeps a voice memo's transcription going in the background and
/// tells the user when the text is ready (#221).
///
/// On Android this is the foreground service and the notifications of the
/// AI chats (#202), over the same method channel. On the desktop nothing
/// happens: there is no service, and no notification.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class VoiceWork {
  /// A transcription starts: keeps the app's process alive, and asks for
  /// the permission to show notifications where Android wants it.
  Future<void> started();

  /// The transcription ended.
  Future<void> finished();

  /// Shows a notification; a tap opens the app.
  Future<void> notify({required String title, required String text});
}

/// No service and no notification: the desktop, and tests.
class NoVoiceWork implements VoiceWork {
  const NoVoiceWork();

  @override
  Future<void> started() async {}

  @override
  Future<void> finished() async {}

  @override
  Future<void> notify({required String title, required String text}) async {}
}

const _channel = MethodChannel('roam_graph/chats');

/// [VoiceWork] on Android; not on other platforms.
class AndroidVoiceWork implements VoiceWork {
  const AndroidVoiceWork();

  Future<void> _call(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Tests, and builds without the channel.
    } on PlatformException {
      // No service or no notification must never stop the transcription.
    }
  }

  @override
  Future<void> started() async {
    // Not awaited: the question waits for the user, the work does not.
    unawaited(_call('requestPermission'));
    await _call('working', {'chats': 1, 'what': 'voice'});
  }

  @override
  Future<void> finished() => _call('idle', {'what': 'voice'});

  @override
  Future<void> notify({required String title, required String text}) =>
      _call('notifyVoice', {'title': title, 'text': text});
}

/// The [VoiceWork] of the platform the app runs on.
VoiceWork platformVoiceWork() => defaultTargetPlatform == TargetPlatform.android
    ? const AndroidVoiceWork()
    : const NoVoiceWork();
