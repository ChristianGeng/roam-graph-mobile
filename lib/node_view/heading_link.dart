/// Links to a heading (#211): `[[id:<id>::*Heading]]`, `[[id:<id>::#custom-id]]`,
/// `[[*Heading]]`, `[[file:note.org::*Heading]]`. The note opens at that
/// heading, with the heading and what is under it unfolded.
library;

import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../edit/org_toggles.dart';

/// The heading a link names: by its title, or by its `:CUSTOM_ID:`.
class NodeHeading {
  const NodeHeading.title(this.text) : customId = false;
  const NodeHeading.customId(this.text) : customId = true;

  /// The title as written in the link, or the custom ID.
  final String text;

  final bool customId;

  /// The heading that a search option (the part after `::`) names, or null
  /// when the option names no heading: `/regexp/`, a line number and
  /// `(coderef)` are not read, and an empty option names nothing.
  ///
  /// `*Heading` is a title, `#id` a custom ID, and text without `*` or `#`
  /// is a title too.
  static NodeHeading? fromOption(String? option) {
    final text = option?.trim() ?? '';
    if (text.isEmpty) return null;
    if (text.startsWith('*')) {
      final title = text.substring(1).trim();
      return title.isEmpty ? null : NodeHeading.title(title);
    }
    if (text.startsWith('#')) {
      final id = text.substring(1).trim();
      return id.isEmpty ? null : NodeHeading.customId(id);
    }
    final isRegexp =
        text.length > 1 && text.startsWith('/') && text.endsWith('/');
    final isLine = RegExp(r'^\d+$').hasMatch(text);
    final isCoderef = text.startsWith('(') && text.endsWith(')');
    if (isRegexp || isLine || isCoderef) return null;
    return NodeHeading.title(text);
  }

  /// What the reader is told when the heading is not in the note.
  String get missingMessage => customId
      ? 'The heading with the custom ID "$text" is no longer in this note.'
      : 'The heading "$text" is no longer in this note.';
}

final _cookie = RegExp(r'\[\d*(?:/\d*|%)\]');

/// [title] as Org compares headings: without statistics cookies like
/// `[2/3]` or `[40%]`, runs of white space as one space, ends trimmed, any
/// case alike. (The TODO keyword, the priority and the tags are not part of
/// a heading's raw title.)
String headingKey(String title) => title
    .replaceAll(_cookie, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

/// The first section of [tree] (with [tree] itself, if it is a section),
/// in the order of the text, that [heading] names; null if there is none.
OrgSection? findHeading(OrgTree tree, NodeHeading heading) {
  final wanted = heading.customId ? heading.text : headingKey(heading.text);
  for (final section in sectionsOf(tree)) {
    final found = heading.customId
        ? section.customIds.any((id) => id.trim() == wanted)
        : headingKey(section.headline.rawTitle ?? '') == wanted;
    if (found) return section;
  }
  return null;
}

/// The sections from the top of [node] down to [target], [target] last;
/// null if [target] is not below [node].
List<OrgSection>? _pathTo(OrgTree node, OrgSection target) {
  if (identical(node, target)) return [target];
  for (final section in node.sections) {
    final below = _pathTo(section, target);
    if (below != null) return [if (node is OrgSection) node, ...below];
  }
  return null;
}

/// How the sections change so that [target], a section of [root], shows,
/// as the states they are in now ([stateOf]) allow: [target] and the
/// sections under it open completely; a heading above it that hides it opens
/// as far as its sub-headings, each as one line (`contents`: its own text
/// stays hidden); nothing else changes. Null if [target] is not in [root].
List<(OrgSection, OrgVisibilityState)>? headingFolding(
  OrgTree root,
  OrgSection target,
  OrgVisibilityState Function(OrgSection section) stateOf,
) {
  final path = _pathTo(root, target);
  if (path == null) return null;
  return [
    for (final section in path.take(path.length - 1))
      if (stateOf(section) == OrgVisibilityState.folded)
        (section, OrgVisibilityState.contents),
    // Each section shows by its own state, so the sections under the
    // target open too.
    // A section a search has hidden stays hidden.
    for (final section in sectionsOf(target))
      if (identical(section, target) ||
          stateOf(section) != OrgVisibilityState.hidden)
        (section, OrgVisibilityState.subtree),
  ];
}

/// Unfolds [target] in the note whose [OrgController] is above [context],
/// as [headingFolding] says. False if [target] is not in the note.
bool unfoldHeading(BuildContext context, OrgSection target) {
  final controller = OrgController.of(context);
  final changes = headingFolding(controller.root, target,
      (section) => controller.nodeFor(section).visibility.value);
  if (changes == null) return false;
  for (final (section, state) in changes) {
    // Each change walks the whole note, so only the ones that change
    // something.
    if (controller.nodeFor(section).visibility.value == state) continue;
    controller.setVisibilityOf(section, (_) => state);
  }
  return true;
}

Element? _find(Element start, bool Function(Widget widget) test) {
  Element? found;
  void walk(Element element) {
    if (found != null) return;
    if (test(element.widget)) {
      found = element;
      return;
    }
    element.visitChildren(walk);
  }

  start.visitChildren(walk);
  return found;
}

/// Scrolls the heading of [target] to the top of the screen and marks it
/// for a moment. [scope] is a context above the note's sections; call it
/// after the frame that built them.
Future<void> revealHeading(BuildContext scope, OrgSection target) async {
  if (scope is! Element) return;
  final section = _find(
      scope, (w) => w is OrgSectionWidget && identical(w.section, target));
  if (section == null) return;
  final headline = _find(section, (w) => w is OrgHeadlineWidget);
  // Read before the scroll: the context is not used after it.
  final overlay = Overlay.maybeOf(scope);
  final color = Theme.of(scope).colorScheme.tertiaryContainer;
  await Scrollable.ensureVisible(section,
      alignment: 0, duration: const Duration(milliseconds: 150));
  if (headline == null || !headline.mounted) return;
  if (overlay == null || !overlay.mounted) return;
  _flash(overlay, color, headline);
}

/// A mark over [headline] that fades out in a moment.
void _flash(OverlayState overlay, Color color, Element headline) {
  final box = headline.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return;
  final overlayBox = overlay.context.findRenderObject();
  if (overlayBox is! RenderBox) return;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.9, end: 0),
          duration: const Duration(milliseconds: 1500),
          onEnd: () => entry.remove(),
          builder: (_, opacity, _) =>
              Opacity(opacity: opacity, child: ColoredBox(color: color)),
        ),
      ),
    ),
  );
  overlay.insert(entry);
}

/// Opens [heading] in [tree], the note shown, before its first frame, then
/// scrolls to it after that frame. Below an [OrgController] whose sections
/// are already in their opening state. [onMissing] is called, after the
/// frame, when the note has no such heading.
class ShowHeading extends StatefulWidget {
  const ShowHeading({
    super.key,
    required this.tree,
    required this.heading,
    required this.onMissing,
    required this.onDone,
    required this.child,
  });

  final OrgTree tree;
  final NodeHeading heading;
  final VoidCallback onMissing;

  /// Called once the heading has been dealt with, so a later rebuild of
  /// the note does not do it again.
  final VoidCallback onDone;
  final Widget child;

  @override
  State<ShowHeading> createState() => _ShowHeadingState();
}

class _ShowHeadingState extends State<ShowHeading> {
  var _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_done) return;
    _done = true;
    var target = findHeading(widget.tree, widget.heading);
    if (target != null && !unfoldHeading(context, target)) target = null;
    final shown = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onDone();
      if (shown != null) {
        revealHeading(context, shown);
      } else {
        // The note opens at the top, also if it was scrolled down.
        Scrollable.ensureVisible(context, alignment: 0);
        widget.onMissing();
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The path of the note [link] names, from the folder of the note
/// [linkingFile] that holds the link, both relative to `roam/`, without
/// `.` and `..` parts; null for an absolute path or one that leaves
/// `roam/`.
String? resolveNotePath(String linkingFile, String link) {
  if (link.isEmpty || link.startsWith('/') || link.startsWith('~')) {
    return null;
  }
  final parts = linkingFile.split('/')..removeLast();
  for (final part in link.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}
