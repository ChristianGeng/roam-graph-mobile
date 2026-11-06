/// How far a note's sections are open when it opens (#63).
library;

import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../settings/view_settings.dart';

/// The state every section of [document] starts in: the file's own
/// `#+STARTUP:` folding word (`overview`, `content`, `showall`,
/// `showeverything`) if it has one, as in Emacs; otherwise [setting].
///
/// `org_flutter` puts the caller's settings before the file's, and reads
/// the file's only when asked to, so the file's word is looked up here.
OrgVisibilityState startupState(OrgDocument document, SectionsOnOpen setting) =>
    OrgSettings.fromDocument(document, (_) {}).startupFolded ?? setting.state;

/// Progress cookies (`[1/3]`, `[33%]`) in a heading's title: a checkbox
/// changes them, and the heading is still the same heading.
final _progressCookie = RegExp(r'\[\d*(?:/\d*|%)\]');

/// The sections of [tree] and below it, by their place in the heading tree: the
/// titles from the top, each with its number among the sections of the
/// same title under the same parent. The objects of one parse are not the
/// objects of the next, but this key is the same for a heading that is
/// still there (#254). Progress cookies in the title are left out. If
/// [tree] is itself a section, it is there too, with the empty key.
///
/// A heading with the same title as a sibling and moved past it takes its
/// number: the folding follows the place, not the text.
Map<String, OrgSection> sectionsByPath(OrgTree tree) {
  final result = <String, OrgSection>{};
  // A heading node's own section has the empty key.
  if (tree is OrgSection) result[''] = tree;
  void walk(OrgTree parent, String prefix) {
    final seen = <String, int>{};
    for (final section in parent.sections) {
      final title = (section.headline.rawTitle ?? '')
          .replaceAll(_progressCookie, '')
          .trim();
      final number = seen[title] = (seen[title] ?? 0) + 1;
      final path = '$prefix$title\u0001$number\u0000';
      result[path] = section;
      walk(section, path);
    }
  }

  walk(tree, '');
  return result;
}

/// How far each section below [tree] is open, by [sectionsByPath]; the
/// state of a section is [stateOf].
Map<String, OrgVisibilityState> foldingByPath(
  OrgTree tree,
  OrgVisibilityState Function(OrgSection) stateOf,
) =>
    {
      for (final MapEntry(:key, :value) in sectionsByPath(tree).entries)
        key: stateOf(value),
    };

/// The state a heading node's own section starts in: open, so its text
/// shows, with its subheadings in [state]. Folded, a heading node would
/// show only its heading line.
OrgVisibilityState openRootState(OrgVisibilityState state) =>
    state == OrgVisibilityState.subtree
        ? OrgVisibilityState.subtree
        : OrgVisibilityState.children;

/// Opens [section], the node shown, to [openRootState] of [state] before
/// it is first drawn. Below an [OrgController] whose sections start in
/// [state].
class OpenSection extends StatefulWidget {
  const OpenSection({
    super.key,
    required this.section,
    required this.state,
    required this.child,
  });

  final OrgSection section;
  final OrgVisibilityState state;
  final Widget child;

  @override
  State<OpenSection> createState() => _OpenSectionState();
}

class _OpenSectionState extends State<OpenSection> {
  var _opened = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Once, before the first build: later taps on the heading decide.
    if (_opened) return;
    _opened = true;
    OrgController.of(context).setVisibilityOf(
        widget.section, (_) => openRootState(widget.state));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
