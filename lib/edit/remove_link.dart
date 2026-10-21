/// Removing one link or image from a note with the trash icons of the node
/// view (#133), and adding a link with "+" (#135). Saved as every edit
/// (decision 10): the diff first, then
/// only over the version read, with the `:ID:` and the drawers as they
/// are and the old version kept. The save indexes the folder again, so the
/// graph and the backlinks change at once.
library;

import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart';
import 'diff_screen.dart';
import 'note_editor.dart';
import 'save_messages.dart';
import 'unlink.dart';

/// Changes the note [file] by [change], after the diff titled [title].
/// Returns what to tell the user: [done] once saved, why nothing was
/// saved, or null when the user went back.
Future<String?> changeNote(
  BuildContext context,
  NoteWriter writer, {
  required String file,
  required String title,
  required String Function(String text) change,
  required String done,
  String saveLabel = 'Save',
}) async {
  final editor = writer.editor;
  if (editor == null) return null;
  final key = editor.store.historyKey(file);
  final base = await editor.read(file);
  if (base == null) return 'Could not read $file as text to change.';
  final String after;
  try {
    after = change(base.text);
  } on NoteChangeError catch (e) {
    return '${e.message} Nothing was changed.';
  }
  if (!context.mounted) return null;
  final save = await DiffScreen.confirm(
    context,
    title: title,
    before: base.text,
    after: after,
    saveLabel: saveLabel,
    backLabel: 'Cancel',
  );
  if (!save) return null;
  // The folder may have changed while the diff was open.
  if (editor.store.historyKey(file) != key) {
    return 'Another folder is open now; nothing was changed.';
  }
  final result = await editor.save(file, base, after);
  if (result is NoWriteAccessToEdit) await writer.allowWriting();
  return saveMessage(result, file) ?? done;
}
