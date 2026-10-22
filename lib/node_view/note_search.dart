/// Search inside the note shown (#152), with `org_flutter`'s own search:
/// [OrgController.searchQuery] marks every match and opens the sections
/// they are in, each mark is a [SearchResult] with a key, and
/// [OrgController.sparseQuery] folds away the sections without a match,
/// as Org's sparse tree (`org-occur`) does.
library;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

/// What [query] matches: the text as typed, upper and lower case alike;
/// null for no search.
RegExp? notePattern(String query) => query.isEmpty
    ? null
    : RegExp(RegExp.escape(query), caseSensitive: false);

/// The sections whose own text (heading and body, not sub-headings)
/// matches [pattern], for "Only matching sections". [root], the note
/// shown, always matches, so a heading node itself never folds away.
class MatchingSections extends OrgQueryMatcher {
  const MatchingSections(this.pattern, this.root);

  final RegExp pattern;
  final OrgTree root;

  @override
  bool matches(OrgSection section) =>
      identical(section, root) ||
      section.contains(pattern, includeChildren: false);

  // `OrgController` folds the sections again whenever the matcher is not
  // equal to the one before, so a rebuild with the same search must give
  // an equal one.
  @override
  bool operator ==(Object other) =>
      other is MatchingSections &&
      other.pattern.pattern == pattern.pattern &&
      identical(other.root, root);

  @override
  int get hashCode => Object.hash(pattern.pattern, identityHashCode(root));
}

/// The marks in [keys] that are on screen, in reading order: top to
/// bottom, then left to right on one line.
List<SearchResultKey> hitsInOrder(Iterable<SearchResultKey> keys) {
  Offset? at(SearchResultKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero);
  }

  final placed = [
    for (final key in keys)
      if (at(key) case final offset?) (key, offset),
  ];
  placed.sort((a, b) {
    final dy = a.$2.dy - b.$2.dy;
    // Marks on one line may differ in height by a little.
    if (dy.abs() >= 2) return dy.sign.toInt();
    return a.$2.dx.compareTo(b.$2.dx);
  });
  return [for (final (key, _) in placed) key];
}

/// What the search bar says about [hits]: "No matches", "3 matches", or
/// "2 of 3" once one is chosen.
String hitCount(List<SearchResultKey> hits, SearchResultKey? selected) {
  if (hits.isEmpty) return 'No matches';
  final i = selected == null ? -1 : hits.indexOf(selected);
  if (i >= 0) return '${i + 1} of ${hits.length}';
  return hits.length == 1 ? '1 match' : '${hits.length} matches';
}

/// Puts the marks of the [OrgController] above into [hits], in reading
/// order, whenever they change, so the search bar outside the controller
/// can count them and go from one to the next.
class NoteSearchHits extends StatefulWidget {
  const NoteSearchHits({super.key, required this.hits, required this.child});

  final ValueNotifier<List<SearchResultKey>> hits;
  final Widget child;

  @override
  State<NoteSearchHits> createState() => _NoteSearchHitsState();
}

class _NoteSearchHitsState extends State<NoteSearchHits> {
  ValueNotifier<List<SearchResultKey>>? _source;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = OrgController.of(context).searchResultKeys;
    if (identical(source, _source)) return;
    _source?.removeListener(_changed);
    _source = source..addListener(_changed);
    _changed();
  }

  /// Whether a copy is waiting for the end of the frame.
  var _pending = false;

  /// The controller changes its list while it builds, and adds the marks
  /// one by one after each frame: one copy at the end of the frame, not
  /// one per mark, since each sorts them all.
  void _changed() {
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      final source = _source;
      if (!mounted || source == null) return;
      widget.hits.value = hitsInOrder(
          source.value.where((key) => key.currentContext?.mounted == true));
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _source?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
