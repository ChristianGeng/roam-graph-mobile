/// Actions on one heading of the node view (#217): the menu of a long
/// press or a right click, the swipes, and the desktop's shortcuts. Each
/// works on the heading with its subtree, as Org's commands do, through
/// the structure edits of "Edit text" (#151).
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../edit/node_text.dart' show headingLine;
import '../edit/structure_edits.dart';

/// What the heading menu offers, in its order.
enum HeadingAction {
  promote('Promote', 'Alt+Shift+Left'),
  demote('Demote', 'Alt+Shift+Right'),
  moveUp('Move up', 'Alt+Up'),
  moveDown('Move down', 'Alt+Down'),
  todo('TODO state…', 'Shift+Left/Right'),
  delete('Delete heading', 'Delete');

  const HeadingAction(this.label, this.shortcut);
  final String label;

  /// The desktop's key for it, as in Org.
  final String shortcut;

  StructureAction? get structure => switch (this) {
        promote => StructureAction.promote,
        demote => StructureAction.demote,
        moveUp => StructureAction.moveUp,
        moveDown => StructureAction.moveDown,
        todo || delete => null,
      };
}

/// Where each heading line of [text] starts, in the order of the text.
/// Line breaks are `\n`, also in a file with `\r\n`.
List<int> headingOffsets(String text) {
  final offsets = <int>[];
  var start = 0;
  while (start <= text.length) {
    final end = text.indexOf('\n', start);
    final line = text.substring(start, end < 0 ? text.length : end);
    if (headingLine.hasMatch(line)) offsets.add(start);
    if (end < 0) break;
    start = end + 1;
  }
  return offsets;
}

/// The start of the heading line of the section number [index] (among
/// [sections], all sections of [text] in order), or null when the lines
/// and the parsed sections do not agree, for example a line with a star
/// inside a block.
int? headingOffset(String text, List<OrgSection> sections, int index) {
  final offsets = headingOffsets(text);
  if (offsets.length != sections.length || index < 0 || index >= offsets.length) {
    return null;
  }
  return offsets[index];
}

/// The number of the heading whose line holds [offset] or is the last one
/// above it.
int? headingIndexAt(String text, int offset) {
  int? found;
  for (final (i, start) in headingOffsets(text).indexed) {
    if (start > offset) break;
    found = i;
  }
  return found;
}

const _noMatch = 'The headings of this note could not be matched to its '
    'lines; use Edit text.';

/// [action] on the heading number [index] of [text] with its subtree, as
/// the button of "Edit text" with the cursor at the start of the heading
/// line. [topLevel] is the highest level a heading may get: 1 in a file
/// node, one below the node's own heading in a heading node.
StructureResult headingStructure(
  StructureAction action,
  String text,
  List<OrgSection> sections,
  int index, {
  required int topLevel,
  required List<OrgTodoStates> todoStates,
}) {
  final at = headingOffset(text, sections, index);
  if (at == null) return const StructureRefused(_noMatch);
  // The TODO state of the note's own heading may change, as before (#150).
  if (action != StructureAction.todo &&
      index < sections.length &&
      sections[index].level < topLevel) {
    return const StructureRefused(
        "The note's own heading changes in Emacs or in its parent note.");
  }
  return applyStructureAction(action, text,
      start: at, end: at, topLevel: topLevel, todoStates: todoStates);
}

/// The heading number [index] of [text] with its subtree cut out, as
/// `org-cut-subtree`: the text after, and the lines removed. A subtree
/// that ends the file leaves the line break before it.
({String after, String removed})? withoutHeading(
    String text, List<OrgSection> sections, int index) {
  final at = headingOffset(text, sections, index);
  if (at == null) return null;
  final level = sections[index].level;
  var end = text.length;
  final offsets = headingOffsets(text);
  for (var i = index + 1; i < offsets.length; i++) {
    if (sections[i].level <= level) {
      end = offsets[i];
      break;
    }
  }
  return (
    after: text.substring(0, at) + text.substring(end),
    removed: text.substring(at, end),
  );
}

final _id = RegExp(r'^[ \t]*:ID:[ \t]+(\S+)[ \t]*$',
    multiLine: true, caseSensitive: false);

/// The `:ID:`s in [text], in order.
List<String> idsIn(String text) => [
      for (final m in _id.allMatches(text.replaceAll('\r\n', '\n'))) m[1]!,
    ];

/// The shown headings of the note below [context] (an element below the
/// [OrgController]), each with its box on screen.
List<(OrgHeadline, RenderBox)> shownHeadlines(BuildContext context) {
  final found = <(OrgHeadline, RenderBox)>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is OrgHeadlineWidget) {
      final box = element.renderObject;
      if (box is RenderBox && box.attached && box.hasSize) {
        found.add((widget.headline, box));
      }
      return;
    }
    element.visitChildren(visit);
  }

  context.visitChildElements(visit);
  return found;
}

/// The headline at [global], a position on screen, or null.
OrgHeadline? headlineAt(BuildContext context, Offset global) {
  for (final (headline, box) in shownHeadlines(context)) {
    final local = box.globalToLocal(global);
    if ((Offset.zero & box.size).contains(local)) return headline;
  }
  return null;
}

/// The box of [headline] on screen, if it is shown.
RenderBox? headlineBox(BuildContext context, OrgHeadline headline) {
  for (final (shown, box) in shownHeadlines(context)) {
    if (identical(shown, headline)) return box;
  }
  return null;
}

/// How far a heading is dragged, and which way; null when none is.
class HeadingDrag {
  const HeadingDrag(this.headline, this.dx, this.width);
  final OrgHeadline headline;
  final double dx;
  final double width;

  /// A swipe acts only past this share of the heading's width.
  static const threshold = 0.4;

  bool get past => dx.abs() >= width * threshold;
}

/// A horizontal drag that starts only where [allowed] says: on a heading
/// line, away from the screen's edges.
class _HeadingDragRecognizer extends HorizontalDragGestureRecognizer {
  _HeadingDragRecognizer(this.allowed);
  final bool Function(Offset global) allowed;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      allowed(event.position) && super.isPointerAllowed(event);
}

/// Around the Org text of a note: finds the heading under a pointer, draws
/// the current heading's light highlight and the swipe's background, and
/// reports a right click and the swipes.
class HeadingGestures extends StatefulWidget {
  const HeadingGestures({
    super.key,
    required this.orgContext,
    required this.current,
    required this.currentChanged,
    required this.showCurrent,
    required this.swipes,
    required this.onPointerDown,
    required this.onSecondaryTap,
    required this.swipeLabel,
    required this.onSwipe,
    required this.child,
  });

  /// A context below the note's [OrgController], to find the headings.
  final BuildContext? Function() orgContext;

  /// The current heading, highlighted when [showCurrent]; [currentChanged]
  /// tells when it changes.
  final OrgHeadline? Function() current;
  final Listenable currentChanged;
  final bool showCurrent;

  /// Whether swipes act (the setting "Swipe actions on headings").
  final bool swipes;

  /// A pointer went down at a heading (null: not on one).
  final void Function(OrgHeadline? headline) onPointerDown;

  /// A right click on [headline], at [global].
  final void Function(OrgHeadline headline, Offset global) onSecondaryTap;

  /// What a swipe to the right ([right] true) or to the left would do,
  /// to show behind the heading.
  final String Function(OrgHeadline headline, {required bool right})
      swipeLabel;

  /// A swipe past the threshold, to the right or to the left.
  final void Function(OrgHeadline headline, {required bool right}) onSwipe;

  final Widget child;

  @override
  State<HeadingGestures> createState() => _HeadingGesturesState();
}

class _HeadingGesturesState extends State<HeadingGestures> {
  final _drag = ValueNotifier<HeadingDrag?>(null);

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  OrgHeadline? _at(Offset global) {
    final orgContext = widget.orgContext();
    if (orgContext == null || !orgContext.mounted) return null;
    return headlineAt(orgContext, global);
  }

  /// Not within the screen's system gesture insets (Android's back
  /// gesture), and at least 20 pixels from each side.
  bool _awayFromEdges(Offset global) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return true;
    final insets = media.systemGestureInsets;
    final left = insets.left > 20 ? insets.left : 20.0;
    final right = insets.right > 20 ? insets.right : 20.0;
    return global.dx >= left && global.dx <= media.size.width - right;
  }

  bool _allowed(Offset global) =>
      widget.swipes && _awayFromEdges(global) && _at(global) != null;

  void _start(DragStartDetails details) {
    final headline = _at(details.globalPosition);
    final orgContext = widget.orgContext();
    if (headline == null || orgContext == null || !orgContext.mounted) return;
    final box = headlineBox(orgContext, headline);
    _drag.value = HeadingDrag(headline, 0, box?.size.width ?? 300);
  }

  void _update(DragUpdateDetails details) {
    final drag = _drag.value;
    if (drag == null) return;
    _drag.value =
        HeadingDrag(drag.headline, drag.dx + details.delta.dx, drag.width);
  }

  void _end(DragEndDetails details) {
    final drag = _drag.value;
    _drag.value = null;
    if (drag == null || !drag.past) return;
    widget.onSwipe(drag.headline, right: drag.dx > 0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget child = CustomPaint(
      foregroundPainter: _HeadingPainter(
        repaint: Listenable.merge([widget.currentChanged, _drag]),
        self: () => context.findRenderObject() as RenderBox?,
        orgContext: widget.orgContext,
        current: widget.showCurrent ? widget.current : () => null,
        drag: _drag,
        label: widget.swipeLabel,
        highlight: scheme.primary.withValues(alpha: 0.10),
        deleteColor: scheme.error,
        onDelete: scheme.onError,
        todoColor: scheme.secondaryContainer,
        onTodo: scheme.onSecondaryContainer,
      ),
      child: widget.child,
    );
    if (widget.swipes) {
      child = RawGestureDetector(
        gestures: {
          _HeadingDragRecognizer:
              GestureRecognizerFactoryWithHandlers<_HeadingDragRecognizer>(
            () => _HeadingDragRecognizer(_allowed),
            (recognizer) => recognizer
              ..onStart = _start
              ..onUpdate = _update
              ..onEnd = _end
              ..onCancel = () => _drag.value = null,
          ),
        },
        child: child,
      );
    }
    return Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons == kSecondaryMouseButton) {
          return;
        }
        widget.onPointerDown(_at(event.position));
      },
      child: GestureDetector(
        onSecondaryTapUp: (details) {
          final headline = _at(details.globalPosition);
          if (headline != null) {
            widget.onSecondaryTap(headline, details.globalPosition);
          }
        },
        child: child,
      ),
    );
  }
}

class _HeadingPainter extends CustomPainter {
  _HeadingPainter({
    required Listenable repaint,
    required this.self,
    required this.orgContext,
    required this.current,
    required this.drag,
    required this.label,
    required this.highlight,
    required this.deleteColor,
    required this.onDelete,
    required this.todoColor,
    required this.onTodo,
  }) : super(repaint: repaint);

  final RenderBox? Function() self;
  final BuildContext? Function() orgContext;
  final OrgHeadline? Function() current;
  final ValueListenable<HeadingDrag?> drag;
  final String Function(OrgHeadline headline, {required bool right}) label;
  final Color highlight, deleteColor, onDelete, todoColor, onTodo;

  /// [headline]'s box in the painter's own coordinates.
  Rect? _rect(OrgHeadline headline) {
    final context = orgContext(), own = self();
    if (context == null || !context.mounted || own == null || !own.attached) {
      return null;
    }
    final box = headlineBox(context, headline);
    if (box == null) return null;
    return own.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (current() case final shown?) {
      if (_rect(shown) case final rect?) {
        canvas.drawRect(rect, Paint()..color = highlight);
      }
    }
    final dragged = drag.value;
    if (dragged == null || dragged.dx == 0) return;
    final rect = _rect(dragged.headline);
    if (rect == null) return;
    final right = dragged.dx > 0;
    final width = dragged.dx.abs().clamp(0.0, rect.width);
    final band = right
        ? Rect.fromLTWH(rect.left, rect.top, width, rect.height)
        : Rect.fromLTWH(rect.right - width, rect.top, width, rect.height);
    final background = right ? todoColor : deleteColor;
    canvas.drawRect(band,
        Paint()..color = background.withValues(alpha: dragged.past ? 1 : 0.6));
    final text = TextPainter(
      text: TextSpan(
        text: label(dragged.headline, right: right),
        style: TextStyle(
            color: right ? onTodo : onDelete,
            fontWeight: dragged.past ? FontWeight.bold : FontWeight.normal),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: rect.width);
    canvas.save();
    canvas.clipRect(band);
    final y = rect.top + (rect.height - text.height) / 2;
    text.paint(
        canvas, Offset(right ? rect.left + 12 : rect.right - text.width - 12, y));
    canvas.restore();
    text.dispose();
  }

  @override
  bool shouldRepaint(_HeadingPainter old) => true;
}
