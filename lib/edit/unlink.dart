/// Removing one link from a note's text (#133): an `id:` link becomes its
/// description, or its target without one, as the agent's `delete_node`
/// does it, so no text is lost; an image link goes with its `#+caption:`,
/// `#+name:`, `#+attr_...:` and `# image prompt:` lines.
///
/// Pure Dart (no Flutter).
library;

/// Why a link could not be removed: the text is not as the app read it.
class UnlinkError implements Exception {
  const UnlinkError(this.message);

  final String message;

  @override
  String toString() => message;
}

final _idLink =
    RegExp(r'\[\[id:([^\]\[]+?)(?:::[^\]]*)?\](?:\[([^\]]*)\])?\]');

/// `<id:x>` and plain `id:x`, as org-roam reads them too
/// (`org_roam_parser.dart`).
final _angleIdLink = RegExp(r'<id:([^>\n]*)>');
final _plainIdLink = RegExp(r'id:([^\[\]\s()<>]+)');
final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
const _punctuation = r'''!"#$%&'()*+,-.:;<=>?@[\]^_`{|}~''';

/// The line of [offset] in [text], from 1.
int _lineOf(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

typedef _FoundLink = ({int start, int end, String target, String text});

/// The `id:` links in [text]: where each is, its target, and the text it
/// becomes. A bracket link becomes its description, or its target without
/// one; an angle or plain link becomes its target.
List<_FoundLink> _idLinks(String text) {
  final found = <_FoundLink>[];
  bool taken(int start, int end) =>
      found.any((f) => start < f.end && f.start < end);
  for (final m in _idLink.allMatches(text)) {
    found.add((
      start: m.start,
      end: m.end,
      target: m.group(1)!.trim(),
      text: m.group(2) ?? m.group(1)!,
    ));
  }
  for (final m in _angleIdLink.allMatches(text)) {
    final target = m.group(1)!.split('::').first.trim();
    if (target.isEmpty || taken(m.start, m.end)) continue;
    found.add((start: m.start, end: m.end, target: target, text: target));
  }
  for (final m in _plainIdLink.allMatches(text)) {
    if (m.start > 0 && _wordChar.hasMatch(text[m.start - 1])) continue;
    // Org leaves trailing punctuation out of a plain link, but a slash.
    var path = m.group(1)!;
    while (path.isNotEmpty &&
        path[path.length - 1] != '/' &&
        _punctuation.contains(path[path.length - 1])) {
      path = path.substring(0, path.length - 1);
    }
    final end = m.start + 3 + path.length;
    final target = path.split('::').first;
    if (target.isEmpty || taken(m.start, end)) continue;
    found.add((start: m.start, end: end, target: target, text: target));
  }
  return found..sort((a, b) => a.start.compareTo(b.start));
}

/// [text] with one `id:` link to [dest] replaced by its text: a bracket
/// link by its description, or by its target without one; an angle
/// `<id:x>` or plain `id:x` link by its target. The link is the one at
/// [pos], org-roam's position (characters from 1); [line] (from 1), when
/// known, narrows the search. Links read back from the index have no
/// line, only the position. Without a link at [pos], the only link to
/// [dest] there, or the first on [line]. Throws [UnlinkError] if none is
/// found.
String withoutIdLink(String text, String dest, {int line = 0, int pos = 0}) {
  final found = [
    for (final link in _idLinks(text))
      if (link.target == dest &&
          (line <= 0 || _lineOf(text, link.start) == line))
        link,
  ];
  _FoundLink? hit;
  if (pos > 0) {
    for (final link in found) {
      if (text.substring(0, link.start).runes.length == pos - 1) hit = link;
    }
  }
  hit ??= found.length == 1 || (line > 0 && found.isNotEmpty)
      ? found.first
      : null;
  if (hit == null) {
    throw const UnlinkError('The link is no longer there; the file changed '
        'since the app read it.');
  }
  return text.replaceRange(hit.start, hit.end, hit.text);
}

final _imageLine = RegExp(
    r'^[ \t]*(?:#\+(?:caption|name|attr_[-_a-z0-9]+)\[?[^\n]*|# image prompt:[^\n]*)$',
    caseSensitive: false);

/// [text] without the image link `[[location]]`. When the link is alone on
/// its line, the line goes, with the lines right above it that belong to
/// the image: `#+caption:`, `#+name:`, `#+attr_...:` and
/// `# image prompt:`. Throws [UnlinkError] if the link is not in [text]
/// exactly once.
String withoutImageLink(String text, String location) {
  final link = RegExp(
      '\\[\\[${RegExp.escape(location)}\\](?:\\[[^\\]]*\\])?\\]');
  final found = link.allMatches(text).toList();
  if (found.isEmpty) {
    throw const UnlinkError('The image link is no longer there; the file '
        'changed since the app read it.');
  }
  if (found.length > 1) {
    throw UnlinkError('The note links to this image ${found.length} times; '
        'remove the one you mean with "Edit text".');
  }
  final hit = found.single;
  final lineStart = text.lastIndexOf('\n', hit.start - 1) + 1;
  final newline = text.indexOf('\n', hit.end);
  final lineEnd = newline < 0 ? text.length : newline;
  final line = text.substring(lineStart, lineEnd);
  if (line.trim() != hit.group(0)) {
    return text.replaceRange(hit.start, hit.end, '');
  }
  // The lines above that belong to the image.
  var start = lineStart;
  while (start > 0) {
    final previousStart = text.lastIndexOf('\n', start - 2) + 1;
    var previous = text.substring(previousStart, start - 1);
    if (previous.endsWith('\r')) previous = previous.substring(0, previous.length - 1);
    if (!_imageLine.hasMatch(previous)) break;
    start = previousStart;
  }
  return text.replaceRange(start, newline < 0 ? lineEnd : newline + 1, '');
}
