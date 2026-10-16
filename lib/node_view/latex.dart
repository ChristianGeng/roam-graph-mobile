import 'package:org_flutter/org_flutter.dart';

/// The delimiters of LaTeX display formulas: `\[ ... \]` and `$$ ... $$`.
/// `\( ... \)` and `$ ... $` are inline formulas.
const displayFormulaDelimiters = {r'\[', r'$$'};

/// [document] with each display formula ([displayFormulaDelimiters]) as a
/// LaTeX block, so `org_flutter` renders it in display mode (#50): in
/// display style (larger sums, integrals and fractions), on its own line,
/// at its start. Emacs shows a preview at the formula's place, not centred
/// (Org 9.7 has no option to centre previews). `org_parser` reads display
/// formulas as inline fragments, and `org_flutter` renders every inline
/// fragment in text mode.
///
/// The block has no environment, so the formula is rendered without its
/// delimiters; one that KaTeX cannot render shows its source with them.
OrgDocument withDisplayFormulas(OrgDocument document) {
  var changed = false;
  final edited = document.edit().visit((location) {
    final node = location.node;
    if (node is OrgLatexInline &&
        displayFormulaDelimiters.contains(node.leadingDecoration)) {
      changed = true;
      return (
        true,
        location.replace(OrgLatexBlock('', '', node.leadingDecoration,
            node.content, node.trailingDecoration, '')),
      );
    }
    return (true, null);
  });
  return changed ? edited.commit<OrgDocument>() : document;
}
