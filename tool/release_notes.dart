// Prints a release's text: the CHANGELOG.md entries added since the
// previous release, then "Built from <sha>."
//
//   dart run tool/release_notes.dart PREVIOUS_CHANGELOG CHANGELOG SHA
//
// PREVIOUS_CHANGELOG is CHANGELOG.md as the previous release had it; a path
// that does not exist means the previous release had none. The release job
// in .github/workflows/build.yml runs this (decision 48).

import 'dart:io';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln('Usage: dart run tool/release_notes.dart '
        'PREVIOUS_CHANGELOG CHANGELOG SHA');
    exit(2);
  }
  final previous = File(args[0]);
  stdout.write(releaseNotes(
    previous.existsSync() ? previous.readAsStringSync() : null,
    File(args[1]).readAsStringSync(),
    args[2],
  ));
}

/// The entries of [current] whose heading [previous] does not have, in the
/// order of [current], then "Built from [sha]." An entry is a `## ` heading
/// and the lines up to the next one.
///
/// Only the top entry when [previous] is null (the previous release had no
/// changelog, so every entry would count as new) or when no entry is new
/// (for example a release built again).
String releaseNotes(String? previous, String current, String sha) {
  final entries = _entries(current);
  final known = previous == null
      ? null
      : {for (final entry in _entries(previous)) entry.first.trim()};
  var added = known == null
      ? <List<String>>[]
      : [for (final entry in entries) if (!known.contains(entry.first.trim())) entry];
  if (added.isEmpty && entries.isNotEmpty) added = [entries.first];
  final text = StringBuffer();
  for (final entry in added) {
    text
      ..writeln(entry.join('\n').trim())
      ..writeln();
  }
  text.writeln('Built from $sha.');
  return text.toString();
}

List<List<String>> _entries(String changelog) {
  final entries = <List<String>>[];
  for (final line in changelog.split('\n')) {
    if (line.startsWith('## ')) {
      entries.add([line]);
    } else if (entries.isNotEmpty) {
      entries.last.add(line);
    }
  }
  return entries;
}
