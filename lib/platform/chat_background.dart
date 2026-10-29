/// What keeps AI chats working in the background and tells me when an
/// answer is ready (#202).
///
/// Two small interfaces, so the chat store can be tested with fakes. On
/// Android they are served by `MainActivity`, a foreground service and the
/// notification manager over one method channel. On the desktop nothing
/// happens: there is no service, and no notification.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Android foreground service that keeps the app's process alive while
/// a chat works.
abstract interface class BackgroundService {
  /// [chats] chats are working: starts the service, or updates the number
  /// in its notification.
  Future<void> working(int chats);

  /// No chat is working: stops the service.
  Future<void> idle();
}

/// The notifications about answers.
abstract interface class AnswerNotifier {
  /// Whether notifications are allowed now. Always true where Android does
  /// not ask for a permission.
  Future<bool> permissionGranted();

  /// Asks for the permission (Android 13 and later); true if it was given.
  Future<bool> requestPermission();

  /// Shows a notification. A tap on it opens the chat [chatId].
  Future<void> show({
    required String chatId,
    required String title,
    required String text,
  });

  /// Calls [onTap] with the ID of the chat when a notification is tapped
  /// while the app runs.
  void listen(void Function(String chatId) onTap);

  /// The ID of the chat whose notification started the app, once; empty
  /// when the notification of the service opened the app; null when the
  /// app was not started from a notification.
  Future<String?> launchTap();
}

/// No service: the desktop, and tests that do not care.
class NoBackgroundService implements BackgroundService {
  const NoBackgroundService();

  @override
  Future<void> working(int chats) async {}

  @override
  Future<void> idle() async {}
}

/// No notifications: the desktop, and tests that do not care.
class NoAnswerNotifier implements AnswerNotifier {
  const NoAnswerNotifier();

  @override
  Future<bool> permissionGranted() async => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> show({
    required String chatId,
    required String title,
    required String text,
  }) async {}

  @override
  void listen(void Function(String chatId) onTap) {}

  @override
  Future<String?> launchTap() async => null;
}

const _channel = MethodChannel('roam_graph/chats');

bool get _onAndroid => defaultTargetPlatform == TargetPlatform.android;

/// [BackgroundService] on Android.
class AndroidBackgroundService implements BackgroundService {
  const AndroidBackgroundService();

  @override
  Future<void> working(int chats) async {
    if (!_onAndroid) return;
    try {
      await _channel.invokeMethod<void>('working', {'chats': chats});
    } on MissingPluginException {
      // Tests, and builds without the channel.
    }
  }

  @override
  Future<void> idle() async {
    if (!_onAndroid) return;
    try {
      await _channel.invokeMethod<void>('idle');
    } on MissingPluginException {
      // Tests, and builds without the channel.
    }
  }
}

/// [AnswerNotifier] on Android.
class AndroidAnswerNotifier implements AnswerNotifier {
  AndroidAnswerNotifier();

  void Function(String chatId)? _onTap;

  @override
  Future<bool> permissionGranted() async {
    if (!_onAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_onAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> show({
    required String chatId,
    required String title,
    required String text,
  }) async {
    if (!_onAndroid) return;
    try {
      await _channel.invokeMethod<void>('notify', {
        'chatId': chatId,
        'title': title,
        'text': text,
      });
    } on MissingPluginException {
      // Tests, and builds without the channel.
    }
  }

  @override
  void listen(void Function(String chatId) onTap) {
    if (!_onAndroid) return;
    _onTap = onTap;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'openRequested') return;
      final id = await launchTap();
      if (id != null) _onTap?.call(id);
    });
  }

  @override
  Future<String?> launchTap() async {
    if (!_onAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('takeOpen');
    } on MissingPluginException {
      return null;
    }
  }
}

/// The service for the platform the app runs on.
BackgroundService platformBackgroundService() =>
    _onAndroid ? const AndroidBackgroundService() : const NoBackgroundService();

/// The notifier for the platform the app runs on.
AnswerNotifier platformAnswerNotifier() =>
    _onAndroid ? AndroidAnswerNotifier() : const NoAnswerNotifier();
