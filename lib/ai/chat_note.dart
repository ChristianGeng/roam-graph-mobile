/// "Save chat as note" (#201): the Org text of a whole chat, with each
/// question and each answer as a heading. The capture screen writes the
/// `:ID:`, `#+title:` and `#+filetags:` (the tag `chat`), so the note is
/// made, and can be undone, like any new node.
///
/// Pure Dart (no Flutter).
library;

import 'ai_chat.dart';

/// The tag the saved note gets.
const chatNoteTag = 'chat';

/// The most characters of a question in its heading.
const _headingLength = 80;

/// A line that would start a heading is quoted with a comma, as Org does
/// in blocks, so an answer cannot break the structure of the note.
String _quoted(String text) => text
    .trim()
    .split('\n')
    .map((line) => RegExp(r'^\*+ ').hasMatch(line) ? ',$line' : line)
    .join('\n');

String _date(DateTime time) {
  final t = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// The title and the Org body of the note for a chat. [title] is the
/// chat's title; [provider] and [model] name who answered.
({String title, String body}) chatAsNote({
  required String title,
  required List<ChatEntry> transcript,
  required String provider,
  required String model,
  required DateTime created,
}) {
  final body = StringBuffer(
      'A chat with the AI ($provider, $model) on ${_date(created)}.\n');
  for (final (index, entry) in transcript.indexed) {
    if (entry is! UserMessage) continue;
    final lines = entry.text.trim().split('\n');
    final first = lines.first.replaceAll(RegExp(r'\s+'), ' ').trim();
    final cut = first.length > _headingLength
        ? '${first.substring(0, _headingLength)}…'
        : first;
    body.write('\n* Question: $cut\n');
    // The whole question, where the heading is not all of it.
    if (lines.length > 1 || cut != first) body.write('${_quoted(entry.text)}\n');
    final answers = <String>[];
    for (final next in transcript.skip(index + 1)) {
      if (next is UserMessage) break;
      if (next is AssistantMessage && next.text.trim().isNotEmpty) {
        answers.add(_quoted(next.text));
      }
    }
    body.write('* Answer\n');
    body.write(answers.isEmpty ? '(No answer.)\n' : '${answers.join('\n\n')}\n');
  }
  final oneLine = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (title: oneLine.isEmpty ? 'Chat' : oneLine, body: body.toString());
}
