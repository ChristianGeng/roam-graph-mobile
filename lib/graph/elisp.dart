/// Emacs Lisp printing as org-roam's database uses it (#5).
///
/// org-roam stores every value through emacsql, which prints it with
/// `prin1` and `print-escape-newlines` and `print-escape-control-characters`
/// set: a string keeps its quotes, a newline becomes `\n`, a tab `\11`.
/// The MCP server reads values in this form, so the app writes them so.
library;

/// A string as `prin1` prints it, quotes included.
String elispString(String text) {
  final out = StringBuffer('"');
  final units = text.runes.toList();
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c == 0x22) {
      out.write(r'\"');
    } else if (c == 0x5C) {
      out.write(r'\\');
    } else if (c == 0x0A) {
      out.write(r'\n');
    } else if (c == 0x0C) {
      out.write(r'\f');
    } else if (c < 0x20 || c == 0x7F) {
      // Octal, with as few digits as needed, unless the next character is
      // an octal digit, as in Emacs's print.c (octalout).
      final next = i + 1 < units.length ? units[i + 1] : -1;
      final digits = c > 0x3F || (next >= 0x30 && next <= 0x37)
          ? 3
          : c > 0x07
              ? 2
              : 1;
      out.write('\\${c.toRadixString(8).padLeft(digits, '0')}');
    } else {
      out.writeCharCode(c);
    }
  }
  out.write('"');
  return out.toString();
}

/// A string with `(inherited t)` text properties over [spans], as Org's
/// ALLTAGS: `#(":a:b:" 1 2 (inherited t))`. Spans count characters.
String elispPropertized(String text, List<(int, int)> spans) {
  if (spans.isEmpty) return elispString(text);
  final out = StringBuffer('#(')..write(elispString(text));
  for (final (start, end) in spans) {
    out.write(' $start $end (inherited t)');
  }
  out.write(')');
  return out.toString();
}

/// A list of strings, or `nil` when empty.
String elispList(List<String> items) =>
    items.isEmpty ? 'nil' : '(${items.map(elispString).join(' ')})';

/// The string inside a printed Emacs Lisp string, undoing [elispString].
/// A value that is not a printed string is returned unchanged.
String decodeElispString(String value) {
  final match = _printedString.firstMatch(value);
  if (match == null) return value;
  return match.group(1)!.replaceAllMapped(_escape, (m) {
    final code = m.group(1)!;
    if (code.startsWith('x')) {
      return String.fromCharCode(int.parse(code.substring(1), radix: 16));
    }
    if ('01234567'.contains(code[0])) {
      return String.fromCharCode(int.parse(code, radix: 8));
    }
    return switch (code) {
      'n' => '\n',
      't' => '\t',
      'f' => '\f',
      'r' => '\r',
      'e' => '\x1B',
      _ => code,
    };
  });
}

/// The strings of the list after [key] in a printed property list: for
/// `:outline` in `(:outline ("A" #("B" 0 1 (face bold))) :search-option
/// "x")`, `A` and `B`. Empty when [key] is missing or its value is `nil`.
List<String> decodeElispPlistStrings(String plist, String key) {
  final start = plist.indexOf('$key ');
  if (start < 0) return const [];
  var i = start + key.length + 1;
  if (!plist.startsWith('(', i)) return const [];
  i++;
  final result = <String>[];
  while (i < plist.length && plist[i] != ')') {
    if (plist[i] == ' ') {
      i++;
      continue;
    }
    // A string with text properties: #("text" 0 4 (...)).
    final propertized = plist.startsWith('#(', i);
    if (propertized) i += 2;
    final match = _printedString.matchAsPrefix(plist, i);
    if (match == null) break;
    result.add(decodeElispString(match.group(0)!));
    i = match.end;
    if (propertized) i = _afterList(plist, i);
  }
  return result;
}

/// The position after the `)` that closes a list whose `(` is before
/// [start], skipping strings and nested lists.
int _afterList(String text, int start) {
  var depth = 1;
  var i = start;
  while (i < text.length && depth > 0) {
    final c = text[i];
    if (c == '"') {
      i = _printedString.matchAsPrefix(text, i)?.end ?? text.length;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') depth--;
    i++;
  }
  return i;
}

final _printedString = RegExp(r'"((?:[^"\\]|\\[\s\S])*)"');
final _escape = RegExp(r'\\(x[0-9A-Fa-f]+|[0-7]{1,3}|[\s\S])');
