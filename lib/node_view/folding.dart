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
