import 'package:highlighting/languages/all.dart';
import 'package:org_flutter/org_flutter.dart';

/// Org's `org-src-lang-modes` in Org 9.7.39: the Emacs mode of a source
/// block's language, without `-mode`. A language not listed here uses the
/// mode of its own name, as `org-src-get-lang-mode` does: `python` is
/// `python-mode`. The keys are compared as written, as in Emacs.
const orgSrcLangModes = {
  'C': 'c', 'C++': 'c++', 'asymptote': 'asy', 'beamer': 'latex', //
  'calc': 'fundamental', 'cpp': 'c++', 'ditaa': 'artist', //
  'desktop': 'conf-desktop', 'dot': 'fundamental', 'elisp': 'emacs-lisp',
  'ocaml': 'tuareg', 'screen': 'shell-script', 'sqlite': 'sql',
  'toml': 'conf-toml', 'shell': 'sh', 'ash': 'sh', 'sh': 'sh', 'bash': 'sh',
  'jsh': 'sh', 'bash2': 'sh', 'dash': 'sh', 'dtksh': 'sh', 'ksh': 'sh',
  'es': 'sh', 'rc': 'sh', 'itcsh': 'sh', 'tcsh': 'sh', 'jcsh': 'sh',
  'csh': 'sh', 'ksh88': 'sh', 'oash': 'sh', 'pdksh': 'sh', 'mksh': 'sh',
  'posix': 'sh', 'wksh': 'sh', 'wsh': 'sh', 'zsh': 'sh', 'rpm': 'sh',
};

/// The highlight.js language for an Emacs mode whose name differs from it.
/// Other modes use their own name: `python` is highlight.js `python`.
const _highlightOfMode = {
  'sh': 'bash',
  'shell-script': 'bash',
  'emacs-lisp': 'lisp',
  'conf': 'ini',
  'conf-toml': 'ini',
  'conf-desktop': 'ini',
  'js': 'javascript',
  'c++': 'cpp',
  'tuareg': 'ocaml',
};

/// The highlight.js language that colours an Org source block of
/// [language] as Emacs colours it, or null for none: the language gives
/// Emacs's mode ([orgSrcLangModes]), the mode gives highlight.js's name.
/// `sh`, `shell` and `zsh` are shell scripts (`bash`); highlight.js's own
/// `shell` is a terminal session with prompts, which Emacs does not use.
///
/// Names are compared as written, as Emacs does: `Python` would need a
/// `Python-mode`, which Emacs does not have, so it stays plain.
String? highlightLanguage(String? language) {
  if (language == null || language.isEmpty) return null;
  final mode = orgSrcLangModes[language] ?? language;
  final id = _highlightOfMode[mode] ?? mode;
  return allLanguages.containsKey(id) ? id : null;
}

/// [document] with each source block's language set to its highlight.js
/// language ([highlightLanguage]), so org_flutter colours it. A block
/// without one, whose own name org_flutter would still colour (it also
/// tries the name in lower case, so `Python` would be coloured as
/// `python`), gets an empty language, which org_flutter shows plain. Other
/// plain blocks keep their language (`mermaid`, for #49). Only the
/// language changes; the block's header line is shown as written.
OrgDocument withHighlightLanguages(OrgDocument document) {
  var changed = false;
  final edited = document.edit().visit((location) {
    final node = location.node;
    if (node is OrgSrcBlock) {
      final language = node.language;
      final id = highlightLanguage(language) ??
          (_orgFlutterColours(language) ? '' : language);
      if (id != language) {
        changed = true;
        return (true, location.replace(node.copyWith(language: id)));
      }
    }
    return (true, null);
  });
  return changed ? edited.commit<OrgDocument>() : document;
}

/// Whether org_flutter colours a block of [language] by its own name
/// (`supportedSrcLanguage`: the name or its lower case).
bool _orgFlutterColours(String? language) =>
    language != null &&
    (allLanguages.containsKey(language) ||
        allLanguages.containsKey(language.toLowerCase()));
