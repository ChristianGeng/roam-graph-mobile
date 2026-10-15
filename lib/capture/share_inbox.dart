import 'package:flutter/services.dart';

/// Text another app shared with this one (#15): the Claude Android app,
/// for example, cannot write files, but it can share text.
class SharedText {
  const SharedText(this.text, {this.subject});

  final String text;

  /// The share's subject, if the sending app gave one.
  final String? subject;
}

/// The title and text a share proposes for the new node: the subject if
/// there is one, otherwise the first line that is not empty, without the
/// `#` of a Markdown heading (AI apps share Markdown). The text is the
/// rest, so the title is not repeated in it.
({String title, String body}) proposeNode(SharedText shared) {
  final subject = shared.subject?.trim() ?? '';
  if (subject.isNotEmpty) {
    return (title: subject, body: shared.text.trim());
  }
  final lines = shared.text.trim().split('\n');
  final first = lines.indexWhere((line) => line.trim().isNotEmpty);
  if (first < 0) return (title: '', body: '');
  final title = lines[first]
      .trim()
      .replaceFirst(RegExp(r'^#+\s*'), '')
      .replaceAll(RegExp(r'^\*\*|\*\*$'), '')
      .trim();
  final body = lines.sublist(first + 1).join('\n').trim();
  return (title: title, body: body);
}

/// Receives text shared with the app through Android's share menu.
///
/// An interface so the screens can be tested without Android.
abstract interface class ShareInbox {
  /// The text shared last, once; null if there is none.
  Future<SharedText?> take();

  /// Calls [onArrived] when text is shared while the app runs.
  void listen(void Function() onArrived);
}

/// [ShareInbox] through `MainActivity.kt`.
class PlatformShareInbox implements ShareInbox {
  const PlatformShareInbox();

  static const _channel = MethodChannel('roam_graph/share');

  @override
  Future<SharedText?> take() async {
    final map = await _channel.invokeMapMethod<String, Object?>('takeShare');
    final text = map?['text'] as String?;
    if (text == null) return null;
    return SharedText(text, subject: map?['subject'] as String?);
  }

  @override
  void listen(void Function() onArrived) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareArrived') onArrived();
    });
  }
}
