import 'package:flutter/services.dart';

import '../platform/desktop.dart';
import 'text_files.dart';

/// What comes into the app: text, or text files (#220).
sealed class Share {
  const Share();
}

/// Text another app shared with this one (#15): the Claude Android app,
/// for example, cannot write files, but it can share text. Also text
/// pasted or dropped on the desktop (#220).
class SharedText extends Share {
  const SharedText(this.text, {this.subject});

  final String text;

  /// The share's subject, if the sending app gave one.
  final String? subject;
}

/// Files shared with the app, dropped onto the window or chosen with
/// "Open files…" (#220); [readTextFiles] checks them.
class SharedFiles extends Share {
  const SharedFiles(this.files);

  final List<IncomingFile> files;
}

/// The title and text a share proposes for the new node: the subject if
/// there is one, otherwise the first line that is not empty, without the
/// `#` of a Markdown heading or the stars of an Org heading, and the `**`
/// of bold, in pairs (AI apps share Markdown; the AI chat writes Org).
/// The text is the rest, so the title is not repeated in it.
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
      // An Org heading, as the AI chat writes (#60): stars and a space.
      .replaceFirst(RegExp(r'^\*+\s+'), '')
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
      .trim();
  final body = lines.sublist(first + 1).join('\n').trim();
  return (title: title, body: body);
}

/// Receives text and files shared with the app through Android's share
/// menu.
///
/// An interface so the screens can be tested without Android.
abstract interface class ShareInbox {
  /// The oldest share not taken yet, once; null if there is none.
  /// Several shares wait in a queue until they are taken.
  Future<Share?> take();

  /// Calls [onArrived] when text is shared while the app runs.
  void listen(void Function() onArrived);
}

/// Sends text to another app through Android's share menu, for example
/// notes to an AI app (#41).
typedef TextSharer = Future<void> Function(String text, {String? subject});

/// [TextSharer] through `MainActivity.kt`.
/// On the desktop, the text goes to the clipboard (#116).
Future<void> shareTextOut(String text, {String? subject}) => isDesktop
    ? copyTextOut(text, subject: subject)
    : const MethodChannel('roam_graph/share')
        .invokeMethod<void>('shareText', {'text': text, 'subject': subject});

/// [ShareInbox] through `MainActivity.kt`.
class PlatformShareInbox implements ShareInbox {
  const PlatformShareInbox();

  static const _channel = MethodChannel('roam_graph/share');

  @override
  Future<Share?> take() async {
    // The desktop has no share menu into the app (#116); files come by
    // drag and drop or "Open files…" instead (#220).
    if (isDesktop) return null;
    final map = await _channel.invokeMapMethod<String, Object?>('takeShare');
    if (map?['files'] case final List<Object?> files) {
      return SharedFiles([
        for (final file in files.whereType<Map<Object?, Object?>>())
          IncomingFile(
            file['name'] as String? ?? '',
            mimeType: file['mimeType'] as String?,
            bytes: file['bytes'] as Uint8List?,
            size: file['size'] as int?,
            error: file['error'] as String?,
            path: file['path'] as String?,
            durationMs: file['durationMs'] as int?,
            isCopy: file['copy'] == true,
          ),
      ]);
    }
    final text = map?['text'] as String?;
    if (text == null) return null;
    return SharedText(text, subject: map?['subject'] as String?);
  }

  @override
  void listen(void Function() onArrived) {
    if (isDesktop) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareArrived') onArrived();
    });
  }
}
