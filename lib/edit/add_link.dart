/// Adding links from the note view and the editor (#135): a note chosen
/// in [NodePicker], or a new one made on the spot, as
/// `org-roam-node-insert` does in Emacs.
library;

import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart';
import '../capture/new_node.dart';
import '../graph/roam_graph.dart';
import 'node_picker.dart';
import 'node_text.dart';
import 'remove_link.dart';
import 'see_also.dart';
import 'unlink.dart';

/// What a link goes to: its ID and title, and the file of the note if it
/// was made just now.
typedef LinkTarget = ({String id, String title, String? newFile});

/// Chooses what to link to; a new note is written at once, as capture
/// writes one (#11): `<time>-<slug>.org`, a new `:ID:`, `#+title:`. It
/// does not open. Null if nothing was chosen, or the new note could not
/// be written; [tell] then says why.
Future<LinkTarget?> chooseLinkTarget(
  BuildContext context,
  NoteWriter writer,
  RoamGraph graph, {
  required void Function(String message) tell,
  RoamNode? proposed,
  Set<String> excluded = const {},
  String title = 'Link to',
  DateTime Function() now = DateTime.now,
}) async {
  final choice = await NodePicker.pickForLink(context, graph,
      proposed: proposed, excluded: excluded, title: title);
  switch (choice) {
    case null:
      return null;
    case ChosenNode(:final node):
      return (id: node.id, title: node.displayTitle, newFile: null);
    case NewNoteTitle(title: final newTitle):
      final id = newOrgId();
      final fileName = nodeFileName(now(), newTitle);
      final result = await writer.create(
          fileName, nodeFileText(id: id, title: newTitle));
      switch (result) {
        case Created() || WrittenNotIndexed():
          return (id: id, title: newTitle, newFile: fileName);
        case NoWriteAccess():
          tell('The app may only read the folder. Choose it again to allow '
              'writing, then add the link again.');
          await writer.allowWriting();
        case FileExists():
          tell('$fileName exists already. Wait a second and try again.');
        case CreateFailed(:final message):
          tell('Could not write $fileName: $message');
      }
      return null;
  }
}

/// Adds a link to [to] to the "See also:" line of [from] (#135), as the
/// agent's `add_link` does, after the diff. Says what happened with
/// [tell], also that a new note made for the link stays when the link is
/// not saved.
Future<void> addSeeAlso(
  BuildContext context,
  NoteWriter writer, {
  required RoamNode from,
  required LinkTarget to,
  required void Function(String message) tell,
}) async {
  final done = 'Linked "${from.displayTitle}" to "${to.title}".';
  final message = await changeNote(
    context,
    writer,
    file: from.file,
    title: 'Link ${from.displayTitle} to ${to.title}',
    change: (text) {
      final lines = NodeLines.find(text, from);
      if (lines == null) {
        throw NoteChangeError('${from.displayTitle} is no longer in '
            '${from.file} with its :ID:; the file changed since the app '
            'read it.');
      }
      return withSeeAlso(lines, to.id, orgLink(to.id, to.title)) ??
          (throw NoteChangeError(
              '"${from.displayTitle}" links to "${to.title}" already.'));
    },
    done: done,
  );
  final newFile = to.newFile;
  if (newFile != null && message != done) {
    tell([
      ?message,
      'The new note roam/$newFile stays, without this link to it.',
    ].join(' '));
  } else if (message != null) {
    tell(message);
  }
}
