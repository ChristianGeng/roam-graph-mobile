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
/// one, by its number among your answers with text and how it begins, so
/// two answers that begin alike are told apart.
String _whichAnswer(String answer, {required bool isLast, int? number}) {
  if (isLast) return 'your last answer';
  final line = answer
      .trim()
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
      .trim();
  final start = line.length > 60 ? '${line.substring(0, 60)}…' : line;
  final which = number == null ? 'your answer' : 'your answer number $number';
  return '$which in this chat, the one that begins "$start"';
}

/// Brackets end an Org link; they are left out of a title in a link.
String _linkTitle(String title) => title.replaceAll(RegExp(r'[\[\]]'), '');

/// The message the button sends in agent mode, shown in the chat as mine.
/// [number] counts the answers with text from 1, for an earlier answer.
/// [start] is the note the chat was opened from, when the AI may see it.
String agentSaveRequest({
  required String answer,
  required bool isLast,
  int? number,
  ({String id, String title})? start,
  String? language,
}) {
  final link = start == null
      ? ''
      : '; and a link to the note I opened the chat from, '
          '[[id:${start.id}][${_linkTitle(start.title)}]]';
  final which = _whichAnswer(answer, isLast: isLast, number: number);
  final words = language == null
      ? 'a short, fitting title in the language of the answer; '
      : 'written in $language, a short, fitting title; ';
  return 'Make a new note from $which with '
      'create_node, $words'
      'the content as Org text, without chat phrases such as greetings, '
      'questions back to me or offers of more help; links in Org syntax to '
      'the notes the answer used, with the IDs the tools gave you$link.';
}

/// The instruction at the end of the extra request. [language] names the
/// language decided for the note (#172), "German (de)".
String noteRequestInstruction({required bool startLinked, String? language}) =>
    'Make a new note from your last answer above${language == null ? '' : ', written in $language'}. '
    'Reply with only a JSON '
    'object, no other text: {"title": "...", "body": "..."}. '
    'title: a short, fitting title${language == null ? ' in the language of the answer' : ''}, one '
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
    {required bool startLinked, String? language}) {
  final entries = <ChatEntry>[];
  for (final entry in transcript.take(answerIndex + 1)) {
    switch (entry) {
      case ModelChanged():
        break;
      case UserMessage():
        entries.add(UserMessage(entry.forModel));
      case AssistantMessage(:final text, :final model, :final searches):
        // The provider's own web searches (#137), as tool results are.
        if (searches.isNotEmpty) {
          entries.add(UserMessage('(What your web searches returned:)\n\n'
              '${_resultsText(searches)}'));
        }
        if (text.trim().isNotEmpty) {
          entries.add(AssistantMessage(text: text, model: model));
        }
      case ToolResults(:final results):
        if (results.isNotEmpty) {
          entries.add(UserMessage('(What the tools you called returned:)'
              '\n\n${_resultsText(results)}'));
        }
    }
  }
  entries.add(UserMessage(
      noteRequestInstruction(startLinked: startLinked, language: language)));
  return entries;
}

String _resultsText(List<ToolResult> results) => [
      for (final result in results)
        '${result.call.name}(${jsonEncode(result.call.input)}):\n'
            '${_cut(result.content)}',
    ].join('\n\n');

String _cut(String text) => text.length <= maxToolResultChars
    ? text
    : '${text.substring(0, maxToolResultChars)}\n(cut here)';

/// The title and body of the model's JSON reply, or null when it cannot be
/// read: no JSON object with a title, or a body that is not text. A code
/// fence or text around the object is allowed, also text with braces: the
/// first balanced object that reads as such a note counts.
///
/// The capture screen writes the `:ID:`, `#+title:` and `#+filetags:`
/// itself, so a `#+title:` or `#+filetags:` line or a properties drawer at
/// the start of the body is dropped, and so is every `:ID:` line in it: an
/// ID the model gave could be one of another note.
({String title, String body})? parseNoteJson(String reply) {
  for (final candidate in _jsonObjects(reply)) {
    Object? json;
    try {
      json = jsonDecode(candidate);
    } on FormatException {
      continue;
    }
    if (json is! Map) continue;
    final title = json['title'];
    final body = json['body'] ?? '';
    if (title is! String || body is! String) continue;
    final oneLine = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.isEmpty) continue;
    return (title: oneLine, body: _cleanBody(body));
  }
  return null;
}

/// The balanced `{…}` spans of [text], in order of their start; braces in
/// JSON strings do not count.
Iterable<String> _jsonObjects(String text) sync* {
  for (var open = text.indexOf('{');
      open >= 0;
      open = text.indexOf('{', open + 1)) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = open; i < text.length; i++) {
      final c = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
      } else if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}' && --depth == 0) {
        yield text.substring(open, i + 1);
        break;
      }
    }
  }
}

String _cleanBody(String body) {
  final lines = body.trim().split('\n');
  final keyword = RegExp(r'^#\+(title|filetags):', caseSensitive: false);
  while (lines.isNotEmpty) {
    final first = lines.first.trim();
    if (keyword.hasMatch(first)) {
      lines.removeAt(0);
    } else if (first.toUpperCase() == ':PROPERTIES:') {
      final end =
          lines.indexWhere((l) => l.trim().toUpperCase() == ':END:');
      if (end < 0) break;
      lines.removeRange(0, end + 1);
    } else if (first.isEmpty) {
      lines.removeAt(0);
    } else {
      break;
    }
  }
  lines.removeWhere(
      (l) => RegExp(r'^\s*:ID:', caseSensitive: false).hasMatch(l));
  return lines.join('\n').trim();
}
