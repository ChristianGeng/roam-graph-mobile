/// LaTeX formulas drawn by the app on every platform (#308, decisions 157
/// and 162), with the `katex` package: Flutter widgets on top of
/// `katex_dart`, a port of KaTeX to Dart. `org_flutter` hands each inline
/// formula to [loadLatexInline] and each LaTeX block to [loadLatexBlock];
/// what they return null for, it shows as source in the code style. The
/// use of the package is kept in this file.
library;

import 'package:flutter/rendering.dart'
    show BoxParentData, Constraints, RenderProxyBox, RenderShiftedBox;
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
/// not become `\pir`). A tag the formula sets itself is drawn when it is
/// laid out ([layOutTagged]).
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

/// The start of a `\tag` or `\tag*` command: after an even number of
/// backslashes, as in [_numbering].
final _tagStart = RegExp(r'(?<=(?:^|[^\\])(?:\\\\)*)\\tag(\*?)\s*\{');

/// [tex] with each `\tag{x}` replaced by `(x)` and each `\tag*{x}` by
/// `x`, a `\qquad` after the formula or its line, each as [drawTag]
/// draws it; with [drop], the tags are left out. `katex_dart` accepts both
/// commands but draws nothing for them, and fails on an `align` whose
/// rows have tags. KaTeX puts the tag at the right edge of the page; a
/// block here has no page width (it is in a container that scrolls
/// sideways), so the tag follows the formula. A tag without its closing
/// brace is left as it is.
String withDrawnTags(String tex, {bool drop = false}) {
  final out = StringBuffer();
  var at = 0;
  // Tags that stand before the end of their row, drawn after the row's
  // mathematical content as amsmath and KaTeX place them, and where that
  // row ends. A tag with only white space after it in its row is drawn
  // where it stands, which is the same place.
  final pending = StringBuffer();
  var pendingEnd = 0;
  void flush() {
    if (pending.isEmpty) return;
    out
      ..write(tex.substring(at, pendingEnd))
      ..write(pending);
    at = pendingEnd;
    pending.clear();
  }

  final scan = _Scan(tex);
  for (final match in _tagStart.allMatches(tex)) {
    if (match.start < at) continue;
    if (pending.isNotEmpty && match.start >= pendingEnd) flush();
    final open = match.end;
    var depth = 1;
    var i = open;
    while (i < tex.length && depth > 0) {
      switch (tex[i]) {
        case '\\':
          i++;
        case '{':
          depth++;
        case '}':
          depth--;
      }
      i++;
    }
    if (depth > 0) break;
    final tag = tex.substring(open, i - 1);
    final shown = match.group(1) == '*' ? tag : '($tag)';
    final drawn = drop ? ' ' : drawTag(shown) ?? ' ';
    out.write(tex.substring(at, match.start));
    at = i;
    // Only a tag at the level of a row moves to the row's end; one in
    // braces, in a nested environment (a `cases`), in an argument or in a
    // comment is drawn where it stands.
    final rowLevel = scan.advance(match.start) && scan.atRowLevel;
    if (i > scan.pos) scan.pos = i;
    if (drop || !rowLevel) {
      out.write(drawn);
      continue;
    }
    if (pending.isEmpty) {
      final end = scan.rowEnd(i);
      if (tex.substring(i, end).trim().isEmpty) {
        out.write(drawn);
        continue;
      }
      pendingEnd = end;
    }
    pending.write(drawn);
  }
  flush();
  return (out..write(tex.substring(at))).toString();
}

/// The environments whose rows a tag can end: the formula itself (no
/// environment) and these, as [formulaToDraw] writes them.
const _rowEnvironments = {
  'align',
  'align*',
  'aligned',
  'alignat',
  'alignat*',
  'alignedat',
  'gather',
  'gather*',
  'gathered',
  'multline',
  'multline*',
  'split',
  'equation',
  'equation*',
  'darray',
};

final _beginEnd = RegExp(r'\\(begin|end)\s*\{([^{}]*)\}');

/// A walk through a formula that keeps the braces and environments it is
/// in, and skips comments (`%` up to the end of the line, not `\%`).
class _Scan {
  _Scan(this.tex);

  final String tex;
  int pos = 0;
  int braces = 0;
  final List<String> environments = [];

  /// Whether the walk is outside braces and directly in the formula or in
  /// an environment of [_rowEnvironments].
  bool get atRowLevel =>
      braces == 0 &&
      (environments.isEmpty || _rowEnvironments.contains(environments.last));

  /// Walks to [to]. False if [to] is inside a comment (the walk then stands
  /// at the comment's end).
  bool advance(int to) {
    while (pos < to) {
      switch (tex[pos]) {
        case '%':
          var end = tex.indexOf('\n', pos);
          if (end < 0) end = tex.length;
          pos = end;
          if (end >= to) return false;
        case '{':
          braces++;
          pos++;
        case '}':
          if (braces > 0) braces--;
          pos++;
        case '\\':
          final match = _beginEnd.matchAsPrefix(tex, pos);
          if (match == null) {
            pos += 2;
          } else {
            if (match.group(1) == 'begin') {
              environments.add(match.group(2)!);
            } else if (environments.isNotEmpty) {
              environments.removeLast();
            }
            pos = match.end;
          }
        default:
          pos++;
      }
    }
    return true;
  }

  /// Where the row that the walk is in ends, looking from [from] on: at the
  /// next row break (`\\`) or `\end` that closes the environment the walk is
  /// in, or the end of the text. A row that ends in a comment without a line
  /// break ends where the comment starts. Row breaks inside braces or inside
  /// an environment that begins after [from] (a `cases` in a row) do not
  /// end it.
  int rowEnd(int from) {
    var depth = 0;
    var open = 0;
    var i = from;
    while (i < tex.length) {
      switch (tex[i]) {
        case '%':
          final end = tex.indexOf('\n', i);
          if (end < 0) return i;
          i = end;
        case '{':
          open++;
          i++;
        case '}':
          if (open > 0) open--;
          i++;
        case '\\':
          if (open > 0) {
            i += 2;
          } else if (tex.startsWith(r'\\', i)) {
            if (depth == 0) return i;
            i += 2;
          } else if (_beginEnd.matchAsPrefix(tex, i) case final match?) {
            if (match.group(1) == 'begin') {
              depth++;
            } else if (depth == 0) {
              return i;
            } else {
              depth--;
            }
            i = match.end;
          } else {
            i += 2;
          }
        default:
          i++;
      }
    }
    return tex.length;
  }
}

/// How one tag, [shown] with its parentheses, is drawn: as text, upright,
/// as amsmath and KaTeX set a tag (`\tag{N2}`, `\tag{$b_1$}`); if
/// `katex_dart` cannot lay that out (`\tag{a_b}`, `\tag{2^{n}}`), as math;
/// null if neither can be.
String? drawTag(String shown) {
  for (final drawn in ['\\text{$shown}', '{$shown}']) {
    if (layOutFormula(drawn).box != null) return '\\qquad$drawn';
  }
  return null;
}

/// [tex] laid out in display mode, or in text mode if [display] is false,
/// with its tags drawn ([withDrawnTags]); if the formula cannot be laid
/// out with them, without them, so a tag never makes the whole formula
/// show its source.
LaidOutFormula layOutTagged(String tex, {bool display = true}) {
  if (!_tagStart.hasMatch(tex)) return layOutFormula(tex, display: display);
  final tagged = layOutFormula(withDrawnTags(tex), display: display);
  if (tagged.box != null) return tagged;
  return layOutFormula(withDrawnTags(tex, drop: true), display: display);
}

/// An inline formula (`\( \)`, `$ $`) drawn on the baseline of the text
/// around it, in its colour and at [katexEm] times its size: `org_flutter`
/// gives the widget the text's style as its [DefaultTextStyle]. A display
/// formula that is still inline (`\[ \]` and `$$ $$` where the text is not
/// passed through `withDisplayFormulas`, as in the AI chat) is drawn in
/// display style. A formula wider than the line scrolls sideways
/// ([DrawnFormula.inline]). Null when the formula cannot be drawn.
InlineSpan? loadLatexInline(OrgLatexInline latex) {
  final display = displayFormulaDelimiters.contains(latex.leadingDecoration);
  final box = display
      ? layOutTagged(latex.content).box
      : layOutFormula(latex.content, display: false).box;
  if (box == null) return null;
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: DrawnFormula(box, source: latex.toMarkup(), inline: true),
  );
}

/// A LaTeX block (an environment, or a display formula that
/// `withDisplayFormulas` made a block) drawn in display mode ([formulaToDraw]).
/// `org_flutter` places it on its own line, at its start, in a container
/// that scrolls sideways. With [align] (from [latexAlignments]: 0.5 for
/// the centre, 1 for the right), it is placed there in the width of the
/// text instead ([AlignedFormula]). Null when the formula cannot be drawn.
Widget? loadLatexBlock(OrgLatexBlock block, {double? align}) {
  final box = layOutTagged(formulaToDraw(block)).box;
  if (box == null) return null;
  final formula = DrawnFormula(
    box,
    source: '${block.begin}${block.content}${block.end}',
  );
  if (align == null || align <= 0) return formula;
  return AlignedFormula(align: align, child: formula);
}

/// The alignments of [document]'s LaTeX blocks, by block (identity), for
/// the ones that `#+ATTR_ORG: :align center` or `right` (or `:center t`)
/// places, as `org_flutter` reads them for an image: 0.5 for the centre, 1
/// for the right. Computed once for each parsed document.
Map<OrgLatexBlock, double> latexAlignments(OrgDocument document) =>
    _alignments[document] ??= _findAlignments(document);

final _alignments = Expando<Map<OrgLatexBlock, double>>();

final _attr = RegExp(r'^#\+attr(.*):$', caseSensitive: false);

Map<OrgLatexBlock, double> _findAlignments(OrgDocument document) {
  final found = Map<OrgLatexBlock, double>.identity();
  document.visit<OrgLatexBlock>((block) {
    if (_alignmentOf(document, block) case final align?) found[block] = align;
    return true;
  });
  return found;
}

/// As `alignmentForNode` in `org_flutter` (`lib/src/util/alignment.dart`),
/// which it does not export: from [block], up to the first node with
/// something before it (so a display formula alone in its paragraph
/// counts, one inside a sentence does not; unlike `org_flutter`, neither
/// does one with text after it in its paragraph), then back through the
/// keywords right before it. `#+ATTR_ORG:` wins over the other
/// `#+ATTR_...:`. Unlike `org_flutter`, which reads every keyword before
/// the node in its section, the keywords must come right before the block,
/// with no blank line between, as in Org, where they belong to the element
/// that follows them.
double? _alignmentOf(OrgDocument document, OrgLatexBlock block) {
  var zipper = document.editNode(block);
  if (zipper == null) return null;
  // A display formula stands in a line of text (a paragraph, a list
  // item's text): to count as the element, it must be all of that text, so
  // nothing but white space may follow it either. Checked only among its
  // own siblings: above them are elements (a list's next item, a quote's
  // next paragraph), which do not matter. An environment is an element
  // itself; what follows it is the next element.
  if (block.environment.isEmpty) {
    for (var right = zipper; right.canGoRight();) {
      right = right.goRight();
      final node = right.node;
      if (node is! OrgPlainText || node.content.trim().isNotEmpty) {
        return null;
      }
    }
  }
  while (!zipper!.canGoLeft()) {
    if (!zipper.canGoUp()) return null;
    zipper = zipper.goUp();
  }
  double? result;
  while (zipper!.canGoLeft()) {
    zipper = zipper.goLeft();
    final node = zipper.node;
    // A blank line after a keyword ends it: it no longer belongs to the
    // element after it (Org's affiliated keywords).
    if (node is! OrgMeta || '\n'.allMatches(node.trailing).length > 1) break;
    final match = _attr.firstMatch(node.key);
    final value = node.value?.toMarkup();
    if (match == null || value == null) continue;
    final authoritative = match.group(1)?.toLowerCase() == '_org';
    final words = value.trim().split(RegExp(r'\s+'));
    String? get(String key) {
      final i = words.indexWhere((word) => word.toLowerCase() == key);
      return i >= 0 && i + 1 < words.length ? words[i + 1] : null;
    }

    if (get(':center') == 't') {
      result = 0.5;
    } else {
      final align = switch (get(':align')?.toLowerCase()) {
        'left' => 0.0,
        'center' => 0.5,
        'right' => 1.0,
        _ => null,
      };
      if (align == null) continue;
      result = align;
    }
    if (authoritative) break;
  }
  return result;
}

/// [child] placed at [align] (0 the start, 1 the end) in the width of the
/// text. `org_flutter` puts a block in a container that scrolls sideways,
/// so the block itself is given no width: the width is that of the
/// nearest box around it that has one (the scroll view's), read during
/// layout. A formula wider than the text keeps its width and scrolls, as
/// one that is not aligned.
class AlignedFormula extends SingleChildRenderObjectWidget {
  const AlignedFormula({super.key, required this.align, required super.child});

  final double align;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderAlignedFormula(align);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAlignedFormula renderObject,
  ) => renderObject.align = align;
}

/// The render object of [AlignedFormula].
///
/// The scroll view gives it the same constraints whatever the text's
/// width, so Flutter would not lay it out again when only that width
/// changes (a window, a side panel, a split view). [layout] therefore
/// raises the minimum width of the constraints to the text's width, read
/// from the boxes around it each time the scroll view lays it out: a new
/// width is new constraints, and Flutter lays it out again by its own
/// rules. Layout and dry layout then use only the constraints.
class RenderAlignedFormula extends RenderShiftedBox {
  RenderAlignedFormula(this._align) : super(null);

  double _align;
  set align(double value) {
    if (value == _align) return;
    _align = value;
    markNeedsLayout();
  }

  /// The width of the nearest box around this one with a bounded width.
  double get _textWidth {
    var node = parent;
    while (node is RenderBox) {
      if (node.constraints.hasBoundedWidth) return node.constraints.maxWidth;
      node = node.parent;
    }
    return 0;
  }

  @override
  void layout(Constraints constraints, {bool parentUsesSize = false}) {
    final box = constraints as BoxConstraints;
    final text = _textWidth.clamp(box.minWidth, box.maxWidth);
    super.layout(box.copyWith(minWidth: text), parentUsesSize: parentUsesSize);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(child!.getDryLayout(constraints.loosen()));

  @override
  void performLayout() {
    final child = this.child!
      ..layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(child.size);
    (child.parentData! as BoxParentData).offset = Offset(
      (size.width - child.size.width) * _align,
      0,
    );
  }
}

/// A formula laid out by `katex_dart`, or why it cannot be.
typedef LaidOutFormula = ({katex.BoxNode? box, Object? error});

/// Formulas laid out, by their text and mode, so scrolling and showing a
/// note again do not parse them again. The layout is in em and has no
/// colour, so one entry serves every theme and text size. The oldest are
/// dropped beyond [maxLaidOutFormulas]: each use moves a formula to the
/// end, so the ones in use stay.
final _laidOut = <(String, bool), LaidOutFormula>{};
const maxLaidOutFormulas = 256;

/// How many formulas are kept laid out.
@visibleForTesting
int get laidOutFormulas => _laidOut.length;

/// Forgets every laid-out formula, so each test starts with none.
@visibleForTesting
void forgetLaidOutFormulas() => _laidOut.clear();

/// The longest formula source that is laid out: 4000 characters, far
/// more than a formula in a note (a long `align` is a few hundred), but a
/// limit for one that an AI answer or a paste makes huge. `katex_dart`
/// lays out on the UI thread, and a huge or deeply nested formula would
/// stop the app; a longer one shows its source.
const maxFormulaLength = 4000;

/// How `katex_dart` lays out a formula; tests replace it to make it fail
/// in other ways than a broken formula.
@visibleForTesting
katex.BoxNode Function(String tex, {katex.KatexOptions? options})
formulaRenderer = katex.renderToBox;

/// [tex] laid out, in display mode unless [display] is false. An unknown
/// command or a broken formula is an error here: `katex_dart` then throws,
/// where the `katex` widgets would draw it in red.
LaidOutFormula layOutFormula(String tex, {bool display = true}) {
  final key = (tex, display);
  if (_laidOut.remove(key) case final laidOut?) return _laidOut[key] = laidOut;
  if (tex.length > maxFormulaLength) {
    return (box: null, error: 'longer than $maxFormulaLength characters');
  }
  LaidOutFormula laidOut;
  try {
    laidOut = (
      box: formulaRenderer(
        tex,
        options: katex.KatexOptions(displayMode: display, throwOnError: true),
      ),
      error: null,
    );
  } on katex.ParseError catch (error) {
    laidOut = (box: null, error: error);
  } on Object catch (error, stack) {
    // Not a broken formula but a fault of the renderer: shown as source
    // too, and logged, so it is seen.
    debugPrint('katex could not lay out $tex: $error\n$stack');
    laidOut = (box: null, error: error);
  }
  _laidOut[key] = laidOut;
  if (_laidOut.length > maxLaidOutFormulas) {
    _laidOut.remove(_laidOut.keys.first);
  }
  return laidOut;
}

/// A laid-out formula ([box]) in the colour of the [DefaultTextStyle] and
/// at [katexEm] times its size. Its size is the formula's own, so it needs
/// no width from its parent; it reports the formula's baseline, so a
/// [WidgetSpan] aligned to the baseline sets it on the line. Screen readers
/// read [source], the formula as written.
///
/// An [inline] formula is in a line of text, which `org_flutter` does not
/// let scroll: it gets its own sideways scroll view, as wide as the line
/// at most, so a formula wider than the line can be read to its end, as a
/// block can in `org_flutter`'s. The scroll view reports the formula's
/// baseline, so the formula stays on the line.
class DrawnFormula extends StatelessWidget {
  const DrawnFormula(
    this.box, {
    super.key,
    required this.source,
    this.inline = false,
  });

  final katex.BoxNode box;
  final String source;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final fontSize = (style.fontSize ?? kDefaultFontSize) * katexEm;
    final formula = Semantics(
      label: source,
      child: _FormulaBox(
        box: box,
        fontSize: fontSize,
        color: style.color ?? Theme.of(context).colorScheme.onSurface,
      ),
    );
    if (!inline) return formula;
    return _WithBaseline(
      baseline: formulaBaseline(box, fontSize),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: formula,
      ),
    );
  }
}

/// The distance from the top of a drawn formula to its baseline: the ink
/// margin, then the part of the formula above its baseline.
double formulaBaseline(katex.BoxNode box, double fontSize) =>
    (kInkOverflowPadEm + box.height) * fontSize;

/// [child], which reports [baseline] as its own: a scroll view reports
/// none.
class _WithBaseline extends SingleChildRenderObjectWidget {
  const _WithBaseline({required this.baseline, required super.child});

  final double baseline;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWithBaseline(baseline);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWithBaseline renderObject,
  ) => renderObject.baseline = baseline;
}

class _RenderWithBaseline extends RenderProxyBox {
  _RenderWithBaseline(this._baseline);

  double _baseline;
  set baseline(double value) {
    if (value == _baseline) return;
    _baseline = value;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => _baseline;
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

  double get _baseline => formulaBaseline(_box, _fontSize);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  /// Painted at its own size; where its parent gave it less room, cut
  /// to its box, so it never paints over what is next to it.
  @override
  void paint(PaintingContext context, Offset offset) {
    final full = _formulaSize;
    if (size.width < full.width || size.height < full.height) {
      context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        (context, offset) => _paintFormula(context.canvas, offset, full),
      );
    } else {
      _paintFormula(context.canvas, offset, full);
    }
  }

  void _paintFormula(Canvas canvas, Offset offset, Size full) {
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    KatexBoxPainter(
      _box,
      fontSize: _fontSize,
      color: _color,
      inkPadEm: kInkOverflowPadEm,
    ).paint(canvas, full);
    canvas.restore();
  }
}
