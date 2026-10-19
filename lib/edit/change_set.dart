/// A change set (#76): edits to several notes that an AI proposes at
/// once, reviewed together and saved one file at a time, each under the
/// rules of decision 10. Built from the pieces of #39: [EditProposal],
/// [applyProposal], [unknownLinkIds] and [NoteEditor.save].
library;

import 'dart:convert';

import '../ai/ai_visibility.dart';
import '../graph/roam_graph.dart';
import 'edit_proposal.dart';
import 'note_editor.dart';

/// What became of one entry of a change set.
enum EntryState {
  /// Proposed, not yet decided.
  pending,

  /// To be saved.
  accepted,

  /// Not to be saved.
  rejected,

  /// Saved.
  saved,

  /// Not saved: the save was refused or failed; [ChangeEntry.problem]
  /// says why.
  refused,

  /// Saved, then undone.
  undone,
}

/// One file of a change set: the proposal, the note as it was when the
/// set was built, and the file as it will be.
class ChangeEntry {
  ChangeEntry({
    required this.proposal,
    required this.node,
    required this.base,
    required this.after,
    required this.unknownIds,
  });

  EditProposal proposal;
  final RoamNode node;

  /// The note as read when the set was built: saved only over this.
  final NoteVersion base;

  /// The file after the edit.
  String after;

  /// `id:` links in the proposed text that point at no node.
  List<String> unknownIds;

  EntryState state = EntryState.pending;

  /// Why it was not saved, for [EntryState.refused].
  String? problem;

  /// The note as it was saved, to undo only if it is still so.
  String? savedHash;

  String get file => node.file;

  /// How many `id:` links the edit adds to the file.
  int get linksAdded =>
      (_idLinks(after) - _idLinks(base.text)).clamp(0, 1 << 30);
}

int _idLinks(String text) => RegExp(r'\[\[id:').allMatches(text).length;

/// Why a set of proposals cannot be a change set.
class ChangeSetError implements Exception {
  const ChangeSetError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Edits to several notes, reviewed together (#76).
class ChangeSet {
  ChangeSet(this.entries, {this.summary = '', this.allOrNothing = false});

  final List<ChangeEntry> entries;
  final String summary;

  /// Whether the set is saved only as a whole (#122): when a file changed
  /// since it was read, no file of the set is saved.
  final bool allOrNothing;

  /// Builds the set from [proposals]: each note is read now, and the edit
  /// applied to it. [visible] is the graph without the notes hidden from
  /// AI, which cannot be part of a set; [graph] is the whole graph, for
  /// checking links. At most [maxFiles] files, one edit per file.
  static Future<ChangeSet> build(
    List<EditProposal> proposals, {
    required NoteEditor editor,
    required RoamGraph visible,
    required RoamGraph graph,
    required int maxFiles,
    String summary = '',
    AiVisibility visibility = AiVisibility.none,
  }) async {
    if (proposals.isEmpty) throw const ChangeSetError('The set is empty.');
    final nodes = <RoamNode>[];
    for (final p in proposals) {
      final node = visible.nodes[p.nodeId];
      if (node == null) {
        throw ChangeSetError(
            'There is no note with the ID ${p.nodeId} that you may see.');
      }
      nodes.add(node);
    }
    final files = {for (final n in nodes) n.file};
    if (files.length != nodes.length) {
      throw const ChangeSetError('Two edits are for the same file; give one '
          'edit per file, with both changes in it.');
    }
    if (files.length > maxFiles) {
      throw ChangeSetError('The set has ${files.length} files; the limit is '
          '$maxFiles. Propose fewer at a time.');
    }
    final entries = <ChangeEntry>[];
    for (var i = 0; i < proposals.length; i++) {
      final node = nodes[i];
      final base = await editor.read(node.file);
      if (base == null) {
        throw ChangeSetError('${node.file} cannot be read.');
      }
      // The file may have got a hidden tag since the index was built.
      if (visibility.hidesInText(node, base.text)) {
        throw ChangeSetError(
            'There is no note with the ID ${node.id} that you may see.');
      }
      final after = applyProposal(base.text, node, proposals[i]);
      if (after == null) {
        throw ChangeSetError('The heading of "${node.displayTitle}" is no '
            'longer in ${node.file}.');
      }
      entries.add(ChangeEntry(
        proposal: proposals[i],
        node: node,
        base: base,
        after: after,
        unknownIds: unknownLinkIds(proposals[i].text, graph),
      ));
    }
    return ChangeSet(entries, summary: summary);
  }

  /// Replaces the proposed text of [entry] with [text], as edited by the
  /// user before accepting it.
  void editEntry(ChangeEntry entry, String text, RoamGraph graph) {
    final proposal = EditProposal(
      nodeId: entry.proposal.nodeId,
      mode: entry.proposal.mode,
      text: text,
      reason: entry.proposal.reason,
    );
    final after = applyProposal(entry.base.text, entry.node, proposal);
    if (after == null) return;
    entry
      ..proposal = proposal
      ..after = after
      ..unknownIds = unknownLinkIds(text, graph);
  }

  Iterable<ChangeEntry> get accepted =>
      entries.where((e) => e.state == EntryState.accepted);

  /// Saves the accepted entries one by one, each over the version it was
  /// built on. A file changed meanwhile is refused alone; the others still
  /// save. [onEach] runs after each file.
  ///
  /// With [allOrNothing], every file is checked first: if one changed
  /// since it was read, none is saved.
  Future<void> save(NoteEditor editor, {void Function()? onEach}) async {
    if (allOrNothing) {
      final changed = <ChangeEntry>{};
      for (final entry in accepted) {
        final now = await editor.read(entry.file);
        if (now == null || now.hash != entry.base.hash) changed.add(entry);
      }
      if (changed.isNotEmpty) {
        for (final entry in accepted.toList()) {
          entry
            ..state = EntryState.refused
            ..problem = changed.contains(entry)
                ? 'Changed on the laptop or through Syncthing since the AI '
                    'read it, so no note of the set was saved.'
                : 'Not saved, because another note of the set changed '
                    'since the AI read it.';
        }
        onEach?.call();
        return;
      }
    }
    for (final entry in accepted.toList()) {
      final result = await editor.save(entry.file, entry.base, entry.after);
      switch (result) {
        case Saved() || SavedNotIndexed() || NothingToSave():
          entry
            ..state = EntryState.saved
            ..savedHash = contentHash(utf8.encode(entry.after));
        case ChangedMeanwhile():
          entry
            ..state = EntryState.refused
            ..problem = 'Changed on the laptop or through Syncthing since '
                'the AI read it.';
        case NoteGone():
          entry
            ..state = EntryState.refused
            ..problem = 'No longer in the folder.';
        case LockedPartChanged():
          entry
            ..state = EntryState.refused
            ..problem = 'Would change an :ID: or a property drawer.';
        case NoWriteAccessToEdit():
          entry
            ..state = EntryState.refused
            ..problem = 'The app may only read the folder.';
        case SaveFailed(:final message):
          entry
            ..state = EntryState.refused
            ..problem = message;
      }
      onEach?.call();
    }
  }

  /// Undoes the saved entries: each file gets back the text it had before
  /// the set, but only if it is still as the set saved it. Returns the
  /// files that could not be undone, with why.
  Future<Map<String, String>> undo(NoteEditor editor) async {
    final problems = <String, String>{};
    for (final entry in entries.where((e) => e.state == EntryState.saved)) {
      final now = await editor.read(entry.file);
      if (now == null) {
        problems[entry.file] = 'cannot be read';
        continue;
      }
      if (now.hash != entry.savedHash) {
        problems[entry.file] = 'changed since the set was saved';
        continue;
      }
      final result = await editor.save(entry.file, now, entry.base.text);
      // NothingToSave: the entry saved no change, so there is none to undo.
      if (result is Saved ||
          result is SavedNotIndexed ||
          result is NothingToSave) {
        entry
          ..state = EntryState.undone
          ..savedHash = null;
      } else {
        problems[entry.file] = 'could not be saved';
      }
    }
    return problems;
  }
}
