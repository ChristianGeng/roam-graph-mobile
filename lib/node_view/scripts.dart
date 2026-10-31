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
    RegExp(r'^[ \t]*#\+OPTIONS:(.*)$', caseSensitive: false, multiLine: true);

/// The mode that the `^:` item of the `#+OPTIONS:` lines of [text] gives,
/// or null when there is none or its value is not `t`, `nil` or `{}`. The
/// last item wins, as in Org. Other items are ignored.
ScriptMode? scriptModeOf(String text) {
  ScriptMode? mode;
  for (final line in _optionsLine.allMatches(text)) {
    for (final item in line.group(1)!.trim().split(RegExp(r'\s+'))) {
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
  return changed ? edited.commit<OrgDocument>() : document;
}
