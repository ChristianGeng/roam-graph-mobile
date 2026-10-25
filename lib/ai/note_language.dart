/// The language of the notes the AI writes (#172): org's own `#+language:`
/// file keyword, read and written here, and the rules that decide it for a
/// new note.
///
/// Pure Dart (no Flutter).
library;

import '../graph/roam_graph.dart';

/// The short list the settings and "Set language…" offer.
const commonLanguages = {
  'en': 'English',
  'de': 'German',
  'fr': 'French',
  'es': 'Spanish',
  'it': 'Italian',
  'nl': 'Dutch',
  'pt': 'Portuguese',
};

/// The language when nothing else decides it, and in settings saved
/// before #172.
const defaultNoteLanguage = 'en';

final _code = RegExp(r'^[a-zA-Z]{2}(?:[-_][a-zA-Z0-9]{2,8})?$');

/// [text] as a language code, `de` or `pt-BR` (ISO 639-1, with an optional
/// region, as org's export dictionary has them), or null when it is none.
String? languageCode(String text) {
  final code = text.trim();
  if (!_code.hasMatch(code)) return null;
  return code.substring(0, 2).toLowerCase() + code.substring(2);
}

/// "German (de)", or the code alone for a language not in
/// [commonLanguages].
String languageName(String code) => switch (commonLanguages[
        code.length >= 2 ? code.substring(0, 2) : code]) {
      final name? => '$name ($code)',
      null => 'the language with the code $code',
    };

final _languageLine =
    RegExp(r'^([ \t]*#\+language:[ \t]*)(\S*)(.*)$', caseSensitive: false);

/// The `#+language:` value of a file's text: the first such line, as org
/// export takes the first value of a keyword like it; null when there is
/// none or it is no language code.
String? languageOf(String text) {
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final match = _languageLine.firstMatch(line);
    if (match != null) return languageCode(match[2]!);
  }
  return null;
}

/// The `#+language:` lines of [text].
List<String> _languageLines(String text) => [
      for (final line in text.split(RegExp(r'\r?\n')))
        if (_languageLine.hasMatch(line)) line.trim(),
    ];

/// Whether [before] and [after] have the same `#+language:` lines: an AI
/// edit never adds or changes one (#172); "Set language…" and
/// `set_language` do that.
bool sameLanguageLines(String before, String after) {
  final a = _languageLines(before), b = _languageLines(after);
  return a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);
}

final _comment = RegExp(r'^[ \t]*#(?: |$)');
final _drawerStart =
    RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
final _drawerEnd = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);
final _keyword = RegExp(r'^[ \t]*#\+[^:\s]*:');
final _title = RegExp(r'^[ \t]*#\+title:', caseSensitive: false);

/// The file [text] with `#+language: [code]`: the first `#+language:` line
/// gets the code; without one, a line goes after `#+title:`, in the file's
/// keyword lines, as org-roam lays a file out. Without a `#+title:`, after
/// the other keyword lines at the top, or the file's property drawer, or
/// at the start. The line endings stay.
String withLanguage(String text, String code) {
  final newline = text.contains('\r\n') ? '\r\n' : '\n';
  final lines = text.split(newline);
  for (var i = 0; i < lines.length; i++) {
    final match = _languageLine.firstMatch(lines[i]);
    if (match != null) {
      lines[i] = '${match[1]}$code${match[3]}';
      return lines.join(newline);
    }
  }
  var at = 0;
  while (at < lines.length && _comment.hasMatch(lines[at])) {
    at++;
  }
  if (at < lines.length && _drawerStart.hasMatch(lines[at])) {
    var end = at + 1;
    while (end < lines.length && !_drawerEnd.hasMatch(lines[end])) {
      end++;
    }
    at = end < lines.length ? end + 1 : 0;
  } else {
    at = 0;
  }
  // The keyword lines from there, with blank lines between them.
  int? title;
  var afterKeywords = at;
  for (var i = at; i < lines.length; i++) {
    if (lines[i].trim().isEmpty) continue;
    if (!_keyword.hasMatch(lines[i])) break;
    if (title == null && _title.hasMatch(lines[i])) title = i;
    afterKeywords = i + 1;
  }
  final insertAt = title != null ? title + 1 : afterKeywords;
  lines.insert(insertAt, '#+language: $code');
  return lines.join(newline);
}

/// A decided language, and why, for the prompt and the tests.
class NoteLanguage {
  const NoteLanguage(this.code, this.rule, {this.from});

  /// The language code, `de`.
  final String code;

  /// The rule of #172 that decided it: 2 (the note it starts from),
  /// 3 (that note's neighbours) or 4 (the default).
  final int rule;

  /// The note it starts from, for rules 2 and 3.
  final RoamNode? from;
}

/// The language of new notes that start from [start] (#172), by the first
/// rule that gives one; rule 1, a wish in the request, is the model's:
///
/// 2. [start]'s file has `#+language:`;
/// 3. most of its linked notes (links and backlinks) that have one, when
///    at least 2 have one and one value has more than half of them;
/// 4. [fallback], "Language of new notes" in AI settings.
///
/// [graph] is the graph the AI may see, so hidden notes do not count;
/// [read] gives a file's text. A heading node takes its file's language.
Future<NoteLanguage> decideLanguage(
  RoamGraph graph,
  RoamNode? start, {
  required Future<String?> Function(String path) read,
  required String fallback,
}) async {
  if (start == null || !graph.nodes.containsKey(start.id)) {
    return NoteLanguage(fallback, 4);
  }
  final byFile = <String, String?>{};
  Future<String?> of(String file) async {
    if (byFile.containsKey(file)) return byFile[file];
    final text = await read(file);
    return byFile[file] = text == null ? null : languageOf(text);
  }

  if (await of(start.file) case final own?) {
    return NoteLanguage(own, 2, from: start);
  }
  final neighbours = <String>{
    for (final link in graph.links)
      if (link.source == start.id && link.dest != start.id)
        link.dest
      else if (link.dest == start.id && link.source != start.id)
        link.source,
  };
  final counts = <String, int>{};
  for (final id in neighbours) {
    final node = graph.nodes[id];
    if (node == null) continue;
    if (await of(node.file) case final code?) {
      counts[code] = (counts[code] ?? 0) + 1;
    }
  }
  final marked = counts.values.fold(0, (sum, n) => sum + n);
  if (marked >= 2) {
    for (final MapEntry(key: code, value: n) in counts.entries) {
      if (n * 2 > marked) return NoteLanguage(code, 3, from: start);
    }
  }
  return NoteLanguage(fallback, 4);
}

/// The sentences on language for the chat's and the agent's system prompt
/// (#172): the language decided in code for new notes, and that edits keep
/// a note's language.
String languagePrompt(NoteLanguage language) {
  final name = languageName(language.code);
  final from = language.from;
  final newNotes = from == null
      ? 'Write new notes in $name.'
      : 'Write new notes linked from "${from.displayTitle}" in $name; '
          'write other new notes in that language too, unless I name '
          'another note they start from.';
  return '$newNotes If my request asks for a language, such as "auf '
      'Deutsch" or "in English", use that one instead, and give its code '
      'to create_node as language. When you change a note, keep its '
      'language: do not translate it unless I ask, and do not add or '
      'change its #+language: line unless I ask.';
}
