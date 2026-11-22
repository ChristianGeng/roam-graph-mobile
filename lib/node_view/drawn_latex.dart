/// LaTeX formulas drawn by the app on every platform (#308, decisions 157
/// and 162), with the `katex` package: Flutter widgets on top of
/// `katex_dart`, a port of KaTeX to Dart. `org_flutter` hands each inline
/// formula to [loadLatexInline] and each LaTeX block to [loadLatexBlock];
/// what they return null for, it shows as source in the code style. The
/// use of the package is kept in this file.
library;

import 'package:katex/katex.dart';
import 'package:katex_dart/katex_dart.dart' as katex;
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import 'latex.dart';

/// KaTeX's math size: 1.21 times the size of the text around it, as its
/// style sheet (`.katex { font-size: 1.21em }`) draws it.
const katexEm = 1.21;

/// `\label{...}`, `\nonumber` and `\notag`: they only label or number an
/// equation. KaTeX in Dart knows none of them and numbers nothing. The
/// backslash must start a command: after an even number of backslashes
/// (`\\notag` is a row break followed by the letters "notag").
final _numbering = RegExp(
  r'(?<=(?:^|[^\\])(?:\\\\)*)\\(?:label\{[^{}]*\}|nonumber\b|notag\b)',
);

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

/// An inline formula (`\( \)`, `$ $`) drawn on the baseline of the text
/// around it, in its colour and at [katexEm] times its size: `org_flutter`
/// gives the widget the text's style as its [DefaultTextStyle]. A display
/// formula that is still inline (`\[ \]` and `$$ $$` where the text is not
/// passed through `withDisplayFormulas`, as in the AI chat) is drawn in
/// display style. Null when the formula cannot be drawn.
InlineSpan? loadLatexInline(OrgLatexInline latex) {
  final display = displayFormulaDelimiters.contains(latex.leadingDecoration);
  final box = layOutFormula(latex.content, display: display).box;
  if (box == null) return null;
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: DrawnFormula(box, source: latex.toMarkup()),
  );
}

/// A LaTeX block (an environment, or a display formula that
/// `withDisplayFormulas` made a block) drawn in display mode ([formulaToDraw]).
/// `org_flutter` places it on its own line, at its start, in a container
/// that scrolls sideways. Null when the formula cannot be drawn.
Widget? loadLatexBlock(OrgLatexBlock block) {
  final box = layOutFormula(formulaToDraw(block)).box;
  if (box == null) return null;
  return DrawnFormula(
    box,
    source: '${block.begin}${block.content}${block.end}',
  );
}

/// A formula laid out by `katex_dart`, or why it cannot be.
typedef LaidOutFormula = ({katex.BoxNode? box, Object? error});

/// Formulas laid out, by their text and mode, so scrolling and showing a
/// note again do not parse them again. The layout is in em and has no
/// colour, so one entry serves every theme and text size. The oldest are
/// dropped beyond [_maxLaidOut].
final _laidOut = <(String, bool), LaidOutFormula>{};
const _maxLaidOut = 256;

/// [tex] laid out, in display mode unless [display] is false. An unknown
/// command or a broken formula is an error here: `katex_dart` then throws,
/// where the `katex` widgets would draw it in red.
LaidOutFormula layOutFormula(String tex, {bool display = true}) {
  final key = (tex, display);
  if (_laidOut.remove(key) case final laidOut?) return _laidOut[key] = laidOut;
  LaidOutFormula laidOut;
  try {
    laidOut = (
      box: katex.renderToBox(
        tex,
        options: katex.KatexOptions(displayMode: display, throwOnError: true),
      ),
      error: null,
    );
  } on Object catch (error) {
    laidOut = (box: null, error: error);
  }
  _laidOut[key] = laidOut;
  if (_laidOut.length > _maxLaidOut) _laidOut.remove(_laidOut.keys.first);
  return laidOut;
}

/// A laid-out formula ([box]) in the colour of the [DefaultTextStyle] and
/// at [katexEm] times its size. Its size is the formula's own, so it needs
/// no width from its parent; it reports the formula's baseline, so a
/// [WidgetSpan] aligned to the baseline sets it on the line. Screen readers
/// read [source], the formula as written.
class DrawnFormula extends StatelessWidget {
  const DrawnFormula(this.box, {super.key, required this.source});

  final katex.BoxNode box;
  final String source;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return Semantics(
      label: source,
      child: _FormulaBox(
        box: box,
        fontSize: (style.fontSize ?? kDefaultFontSize) * katexEm,
        color: style.color ?? Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

/// Paints [box] with `katex`'s [KatexBoxPainter], with its ink margin on
/// every side ([kInkOverflowPadEm]), and reports its baseline.
class _FormulaBox extends LeafRenderObjectWidget {
  const _FormulaBox({
    required this.box,
    required this.fontSize,
    required this.color,
  });

  final katex.BoxNode box;
  final double fontSize;
  final Color color;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderFormula(box, fontSize, color);

  @override
  void updateRenderObject(BuildContext context, RenderFormula renderObject) {
    renderObject
      ..box = box
      ..fontSize = fontSize
      ..color = color;
  }
}

/// The render object of [DrawnFormula]; tests read its painter's values.
class RenderFormula extends RenderBox {
  RenderFormula(this._box, this._fontSize, this._color);

  katex.BoxNode _box;
  katex.BoxNode get box => _box;
  set box(katex.BoxNode value) {
    if (identical(value, _box)) return;
    _box = value;
    markNeedsLayout();
  }

  double _fontSize;
  double get fontSize => _fontSize;
  set fontSize(double value) {
    if (value == _fontSize) return;
    _fontSize = value;
    markNeedsLayout();
  }

  Color _color;
  Color get color => _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  Size get _formulaSize => boxSizePxPadded(_box, _fontSize);

  @override
  double computeMinIntrinsicWidth(double height) => _formulaSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _formulaSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _formulaSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _formulaSize.height;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_formulaSize);

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => _baseline;

  @override
  void performLayout() => size = computeDryLayout(constraints);

  /// The ink margin, then the part of the formula above its baseline.
  double get _baseline => (kInkOverflowPadEm + _box.height) * _fontSize;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    KatexBoxPainter(
      _box,
      fontSize: _fontSize,
      color: _color,
      inkPadEm: kInkOverflowPadEm,
    ).paint(context.canvas, size);
    context.canvas.restore();
  }
}
