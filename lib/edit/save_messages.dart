import 'note_editor.dart';

/// What to tell the user about [result], the save of [file]; null when it
/// was saved and nothing needs saying.
String? saveMessage(SaveResult result, String file) => switch (result) {
      Saved() || NothingToSave() => null,
      SavedNotIndexed(:final message) =>
        'Saved; the graph shows it after the next scan ($message).',
      ChangedMeanwhile() => '$file changed on the laptop or through '
          'Syncthing since the app read it, so nothing was saved.',
      NoteGone() => '$file is no longer in the folder.',
      LockedPartChanged() => 'The :ID: and the property drawers stay as '
          'they are; this change would alter them, so nothing was saved.',
      NoWriteAccessToEdit() => 'The app may only read the folder. Choose it '
          'again to allow writing.',
      SaveFailed(:final message) => 'Could not save: $message',
    };
