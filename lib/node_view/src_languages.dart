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
String? highlightLanguage(String? language) {
  if (language == null || language.isEmpty) return null;
  final mode = orgSrcLangModes[language] ?? language;
  final id = _highlightOfMode[mode] ?? mode;
  if (allLanguages.containsKey(id)) return id;
  // org_flutter also tries the name in lower case, as before.
  final lower = id.toLowerCase();
  return allLanguages.containsKey(lower) ? lower : null;
}

/// [document] with each source block's language set to its highlight.js
/// language ([highlightLanguage]), so org_flutter colours it. Blocks
/// without one keep their language and are shown plain, as before. Only
/// the language changes; the block's header line is shown as written.
OrgDocument withHighlightLanguages(OrgDocument document) {
  var changed = false;
  final edited = document.edit().visit((location) {
    final node = location.node;
    if (node is OrgSrcBlock) {
      final id = highlightLanguage(node.language);
      if (id != null && id != node.language) {
        changed = true;
        return (true, location.replace(node.copyWith(language: id)));
      }
    }
    return (true, null);
  });
  return changed ? edited.commit<OrgDocument>() : document;
}
