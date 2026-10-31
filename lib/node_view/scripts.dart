import 'package:org_flutter/org_flutter.dart';

/// When `_` and `^` make a subscript or superscript (#213): the values of
/// Org's `#+OPTIONS: ^:` item.
enum ScriptMode {
  /// `^:{}`: only `a_{b}` and `x^{2}`.
  braces('Only with braces',
      'a_{b} and x^{2} are small; real_time_streaming shows as typed', '{}'),

  /// `^:nil`: never.
  never('As typed', '_ and ^ always show as typed', 'nil'),

  /// `^:t`: always, whatever follows the sign.
  always('Always', 'The text after every _ or ^ is small', 't');

  const ScriptMode(this.label, this.description, this.option);

  final String label;
  final String description;

  /// The value of `^:` in `#+OPTIONS:` with this meaning.
  final String option;
}

final _optionsLine =
    RegExp(r'^[ \t]*#\+OPTIONS:(.*)$', caseSensitive: false);
final _blockStart = RegExp(r'^[ \t]*#\+BEGIN_', caseSensitive: false);
final _blockEnd = RegExp(r'^[ \t]*#\+END_', caseSensitive: false);

/// The mode that the `^:` item of the `#+OPTIONS:` lines of [text] gives,
/// or null when there is none or its value is not `t`, `nil` or `{}`. The
/// last item wins, as in Org. Other items are ignored, and so are lines
/// inside blocks (a source block that shows an example `#+OPTIONS:` line).
ScriptMode? scriptModeOf(String text) {
  ScriptMode? mode;
  var inBlock = false;
  for (final line in text.split('\n')) {
    if (inBlock) {
      if (_blockEnd.hasMatch(line)) inBlock = false;
      continue;
    }
    if (_blockStart.hasMatch(line)) {
      inBlock = true;
      continue;
    }
    final match = _optionsLine.firstMatch(line);
    if (match == null) continue;
    for (final item in match.group(1)!.trim().split(RegExp(r'\s+'))) {
      if (!item.startsWith('^:')) continue;
      final value = item.substring(2);
      for (final candidate in ScriptMode.values) {
        if (candidate.option == value) mode = candidate;
      }
    }
  }
  return mode;
}

/// [document] with the subscripts and superscripts that [mode] does not
/// allow turned back into the text as written: `_`, `^` and braces in
/// normal size. LaTeX, verbatim and code are other nodes and stay as they
/// are. [ScriptMode.always] is how `org_parser` reads a note, so it changes
/// nothing.
OrgDocument withScripts(OrgDocument document, ScriptMode mode) {
  if (mode == ScriptMode.always) return document;
  var changed = false;
  final edited = document.edit().visit((location) {
    final node = location.node;
    if (node is OrgSubscript || node is OrgSuperscript) {
      final markup = node.toMarkup();
      final braces = markup.length > 1 && markup[1] == '{';
      if (mode == ScriptMode.never || !braces) {
        changed = true;
        return (true, location.replace(OrgPlainText(markup)));
      }
    }
    return (true, null);
  });
  if (!changed) return document;
  return _joinedText(edited.commit<OrgDocument>());
}

/// [document] with neighbouring plain text nodes joined into one, so that
/// `real_time_streaming` is one piece of text again for the search and its
/// marks, not three.
OrgDocument _joinedText(OrgDocument document) {
  var changed = false;
  final edited = document.edit().visit((location) {
    final node = location.node;
    if (node is OrgContent && _hasNeighbourText(node.children)) {
      final children = <OrgNode>[];
      for (final child in node.children) {
        if (child is OrgPlainText &&
            children.isNotEmpty &&
            children.last is OrgPlainText) {
          final last = children.removeLast() as OrgPlainText;
          children.add(OrgPlainText(last.content + child.content));
        } else {
          children.add(child);
        }
      }
      changed = true;
      return (true, location.replace(OrgContent(children)));
    }
    return (true, null);
  });
  return changed ? edited.commit<OrgDocument>() : document;
}

bool _hasNeighbourText(List<OrgNode> children) {
  for (var i = 1; i < children.length; i++) {
    if (children[i] is OrgPlainText && children[i - 1] is OrgPlainText) {
      return true;
    }
  }
  return false;
}
