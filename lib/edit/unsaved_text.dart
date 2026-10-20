/// The editor screens that have text not saved yet (#133). While one has,
/// the folder is not checked for changes from outside, so the note it
/// edits is not read again under it.
///
/// Pure Dart (no Flutter).
library;

class UnsavedText {
  UnsavedText._();

  static final _owners = <Object>{};

  /// Whether any editor has text not saved yet.
  static bool get any => _owners.isNotEmpty;

  /// Marks [owner], an editor screen, as having text not saved yet, or
  /// not; an editor that closes marks itself as not.
  static void mark(Object owner, bool unsaved) =>
      unsaved ? _owners.add(owner) : _owners.remove(owner);
}
