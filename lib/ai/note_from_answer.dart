/// "Save as new node" under a chat answer (#145): the AI makes the note
/// from the answer, with a fitting title and Org text, instead of the
/// answer's first line becoming the title.
///
/// - In agent mode the button sends [agentSaveRequest] as my message; the
///   agent makes the note with `create_node`, in the normal agent loop.
/// - In review and off mode the app asks the model once more, without
///   tools ([noteRequestEntries], [noteFromAnswerSystem]), for a JSON
///   object `{"title", "body"}` ([parseNoteJson]) that fills "New node".
///
/// Pure Dart (no Flutter).
library;

import 'dart:convert';

import 'ai_chat.dart';

/// The system prompt of the extra request in review and off mode.
const noteFromAnswerSystem =
    'You turn an answer from a chat about my org-roam notes (Org mode '
    'files, linked by IDs) into a new note. You have no tools here. Reply '
    'with the JSON object you are asked for and nothing else.';

/// The most characters of one tool result in the extra request: enough
/// for the IDs and titles, without sending long notes again in full.
const maxToolResultChars = 4000;

/// The words that name the answer: "your last answer", or, for an earlier
/// one, by how it begins.
String _whichAnswer(String answer, {required bool isLast}) {
  if (isLast) return 'your last answer';
  final line = answer
      .trim()
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
      .trim();
  final start = line.length > 60 ? '${line.substring(0, 60)}…' : line;
  return 'your answer that begins "$start"';
}

/// Brackets end an Org link; they are left out of a title in a link.
String _linkTitle(String title) => title.replaceAll(RegExp(r'[\[\]]'), '');

/// The message the button sends in agent mode, shown in the chat as mine.
/// [start] is the note the chat was opened from, when the AI may see it.
String agentSaveRequest({
  required String answer,
  required bool isLast,
  ({String id, String title})? start,
}) {
  final link = start == null
      ? ''
      : '; and a link to the note I opened the chat from, '
          '[[id:${start.id}][${_linkTitle(start.title)}]]';
  return 'Make a new note from ${_whichAnswer(answer, isLast: isLast)} with '
      'create_node: a short, fitting title in the language of the answer; '
      'the content as Org text, without chat phrases such as greetings, '
      'questions back to me or offers of more help; links in Org syntax to '
      'the notes the answer used, with the IDs the tools gave you$link.';
}

/// The instruction at the end of the extra request.
String noteRequestInstruction({required bool startLinked}) =>
    'Make a new note from your last answer above. Reply with only a JSON '
    'object, no other text: {"title": "...", "body": "..."}. '
    'title: a short, fitting title in the language of the answer, one '
    'line, without markup. '
    'body: the content as Org mode text, without chat phrases such as '
    'greetings, questions back to me or offers of more help, and without '
    'the title, a #+title: line or a properties drawer. Link the notes the '
    'answer used in Org syntax, [[id:<ID>][<title>]], only with IDs that '
    'appear in this conversation.'
    '${startLinked ? ' Do not link the note I opened the chat from; the '
        'app adds that link.' : ''}';

/// The conversation for the extra request: the entries up to the answer
/// at [answerIndex], as plain text (no tool calls, so no tools need to be
/// offered), then [noteRequestInstruction].
///
/// The tool results become text in a message of mine, cut to
/// [maxToolResultChars], so the IDs the tools gave stay in. Images are not
/// sent again. Nothing goes in that was not sent to the same provider in
/// this chat already.
List<ChatEntry> noteRequestEntries(List<ChatEntry> transcript, int answerIndex,
    {required bool startLinked}) {
  final entries = <ChatEntry>[];
  for (final entry in transcript.take(answerIndex + 1)) {
    switch (entry) {
      case UserMessage():
        entries.add(UserMessage(entry.forModel));
      case AssistantMessage(:final text, :final model):
        if (text.trim().isNotEmpty) {
          entries.add(AssistantMessage(text: text, model: model));
        }
      case ToolResults(:final results):
        final parts = [
          for (final result in results)
            '${result.call.name}(${jsonEncode(result.call.input)}):\n'
                '${_cut(result.content)}',
        ];
        if (parts.isNotEmpty) {
          entries.add(UserMessage(
              '(What the tools you called returned:)\n\n${parts.join('\n\n')}'));
        }
    }
  }
  entries.add(UserMessage(noteRequestInstruction(startLinked: startLinked)));
  return entries;
}

String _cut(String text) => text.length <= maxToolResultChars
    ? text
    : '${text.substring(0, maxToolResultChars)}\n(cut here)';

/// The title and body of the model's JSON reply, or null when it cannot be
/// read: no JSON object, no title, or a body that is not text. A code
/// fence or text around the object is allowed; a `#+title:` or
/// `#+filetags:` line at the start of the body is dropped, as the capture
/// screen writes those.
({String title, String body})? parseNoteJson(String reply) {
  final open = reply.indexOf('{');
  final close = reply.lastIndexOf('}');
  if (open < 0 || close <= open) return null;
  Object? json;
  try {
    json = jsonDecode(reply.substring(open, close + 1));
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  final title = json['title'];
  final body = json['body'] ?? '';
  if (title is! String || body is! String) return null;
  final oneLine = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.isEmpty) return null;
  final lines = body.trim().split('\n');
  while (lines.isNotEmpty &&
      RegExp(r'^#\+(title|filetags):', caseSensitive: false)
          .hasMatch(lines.first.trim())) {
    lines.removeAt(0);
  }
  return (title: oneLine, body: lines.join('\n').trim());
}
