/// LaTeX blocks drawn by the app on Linux, Windows and macOS (#300,
/// decision 157), with the `katex` package: Flutter widgets on top of
/// `katex_dart`, a port of KaTeX to Dart. Android and iOS keep
/// `org_flutter`'s `flutter_tex_js` (decision 40). The use of the package
/// is kept in this file.
///
/// As Mermaid and PlantUML (`diagram_blocks.dart`): after parsing, each
/// LaTeX block is replaced by a link that stands for its drawing, and the
/// node view's `loadImage` draws it. Inline formulas stay as they are:
/// `org_flutter` places a `loadImage` widget at the bottom of the line,
/// not on the text baseline.
library;

import 'package:katex/katex.dart';
import 'package:katex_dart/katex_dart.dart' as katex;
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../platform/desktop.dart';

/// The location of the links that stand for a formula. The location itself
/// is not read: a link the note writes with it stays a link ([FormulaLink]).
const _formulaLocation = 'latex-formula.png';

/// KaTeX's math size: 1.21 times the size of the text around it, as its
/// style sheet (`.katex { font-size: 1.21em }`) and so `flutter_tex_js` on
/// Android draw it.
const katexEm = 1.21;

/// A link that stands for the drawing of a LaTeX block: [tex] is the
/// formula to draw ([formulaToDraw]), [source] the block as written, with
/// its delimiters, shown when the formula cannot be drawn.
///
/// [contains] gives the formula's source, so a section with a match in a
/// formula still shows when the note is searched, as with the LaTeX block
/// it replaces. As there, the match itself is not marked or jumped to.
class FormulaLink extends OrgBracketLink {
  FormulaLink(this.tex, {required this.source}) : super(_formulaLocation, null);

  final String tex;
  final String source;

  @override
  bool contains(Pattern pattern) => source.contains(pattern);
}

/// [document] with each LaTeX block (environments, and the display
/// formulas `withDisplayFormulas` turned into blocks) replaced by a
/// [FormulaLink], on Linux, Windows and macOS. On Android and iOS, and in a
/// note with `#+STARTUP: noinlineimages` (`org_flutter` then never calls
/// `loadImage`), [document] is returned as it is.
///
/// A display formula stands inside its paragraph, so it becomes the link
/// alone; an environment is an element of its own, so it becomes a
/// paragraph with the link, with the block's indent and blank lines after.
OrgDocument withDrawnFormulas(OrgDocument document) {
  if (!isDesktop) return document;
  if (OrgSettings.fromDocument(document, (_) {}).inlineImages == false) {
    return document;
  }
  var changed = false;
  final edited = document.edit().visit((location) {
    final node = location.node;
    if (node is! OrgLatexBlock) return (true, null);
    changed = true;
    final link = FormulaLink(
      formulaToDraw(node),
      source: '${node.begin}${node.content}${node.end}',
    );
    return (
      true,
      location.replace(
        node.environment.isEmpty
            ? link
            : OrgParagraph(node.indent, OrgContent([link]), node.trailing),
      ),
    );
  });
  return changed ? edited.commit<OrgDocument>() : document;
}

/// `\label{...}`, `\nonumber` and `\notag`: they only label or number an
/// equation. KaTeX in Dart knows none of them and numbers nothing.
final _numbering = RegExp(r'\\label\{[^{}]*\}|\\nonumber\b|\\notag\b');

/// The formula of [block] as `katex_dart` can draw it. It knows the
/// environments inside a formula (`aligned`, `cases`, `pmatrix`, ...) but
/// not most of the ones that stand alone, so those are rewritten:
///
/// - a display formula (no environment), `equation` and `equation*`: the
///   formula itself;
/// - `align`: `aligned`;
/// - `gather`, `gather*`, `multline` and `multline*`: `darray{c}`, one
///   centred line for each line, in display style (`array` would set its
///   cells in text style);
/// - every other environment is passed as it is.
///
/// Equation numbers are lost: `katex_dart` numbers nothing, and the
/// commands that label or number ([_numbering]) are removed, each replaced
/// by a space so the commands around it stay apart (`\pi\label{a}r` must
/// not become `\pir`).
String formulaToDraw(OrgLatexBlock block) {
  final body = block.content.replaceAll(_numbering, ' ');
  return switch (block.environment) {
    '' || 'equation' || 'equation*' => body,
    'align' => '\\begin{aligned}$body\\end{aligned}',
    'gather' ||
    'gather*' ||
    'multline' ||
    'multline*' => '\\begin{darray}{c}$body\\end{darray}',
    _ => '${block.begin}$body${block.end}',
  };
}

/// The drawing for [link], if [withDrawnFormulas] added it; else null.
Widget? loadDrawnFormula(OrgLink link) => switch (link) {
  final FormulaLink link => DrawnFormula(link.tex, source: link.source),
  _ => null,
};

/// A formula laid out by `katex_dart`, or why it cannot be.
typedef LaidOutFormula = ({katex.BoxNode? box, Object? error});

/// Formulas laid out, by their text, so scrolling and showing a note again
/// do not parse them again. The layout is in em and has no colour, so one
/// entry serves every theme and text size. The oldest are dropped beyond
/// [_maxLaidOut].
final _laidOut = <String, LaidOutFormula>{};
const _maxLaidOut = 256;

/// [tex] laid out in display mode. An unknown command or a broken formula
/// is an error here: `katex_dart` then throws, where the `katex` widget
/// would draw it in red.
LaidOutFormula layOutFormula(String tex) {
  if (_laidOut.remove(tex) case final laidOut?) return _laidOut[tex] = laidOut;
  LaidOutFormula laidOut;
  try {
    laidOut = (
      box: katex.renderToBox(
        tex,
        options: const katex.KatexOptions(
          displayMode: true,
          throwOnError: true,
        ),
      ),
      error: null,
    );
  } on Object catch (error) {
    laidOut = (box: null, error: error);
  }
  _laidOut[tex] = laidOut;
  if (_laidOut.length > _maxLaidOut) _laidOut.remove(_laidOut.keys.first);
  return laidOut;
}

/// A LaTeX block drawn in display mode, on its own line, at its start, as
/// on Android (decision 40). It has the colour of the text and KaTeX's
/// size, [katexEm] times the text size (with the system's text scaling, as
/// the text). A formula wider than the text column scrolls sideways. One
/// that cannot be drawn shows [source] in the text style, as on Android.
class DrawnFormula extends StatelessWidget {
  const DrawnFormula(this.tex, {super.key, required this.source});

  final String tex;
  final String source;

  @override
  Widget build(BuildContext context) {
    final box = layOutFormula(tex).box;
    if (box == null) return Text(source);
    final style = DefaultTextStyle.of(context).style;
    final fontSize = MediaQuery.textScalerOf(
      context,
    ).scale((style.fontSize ?? 14) * katexEm);
    final size = boxSizePxPadded(box, fontSize);
    // The full width of the text column, so a wide formula scrolls inside
    // it. Where the width is unbounded (org_flutter puts a link with
    // `#+ATTR_ORG: :align` into a Row), the formula's own width instead:
    // LimitedBox acts only then, and keeps intrinsic sizes working.
    return LimitedBox(
      maxWidth: size.width,
      child: ConstrainedBox(
        constraints: const BoxConstraints.tightFor(width: double.infinity),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // Screen readers read the formula's source.
          child: Semantics(
            label: source,
            child: CustomPaint(
              size: size,
              painter: KatexBoxPainter(
                box,
                fontSize: fontSize,
                color: style.color ?? Theme.of(context).colorScheme.onSurface,
                inkPadEm: kInkOverflowPadEm,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
