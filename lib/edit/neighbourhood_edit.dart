/// "Edit with AI" on a note and its neighbourhood (#122): the note, the
/// notes that link to it and the notes it links to. The AI first says
/// what it will do (a plan), and only after "Go ahead" writes the new
/// texts, which are reviewed together as a change set (#76).
///
/// Pure Dart (no Flutter): the scope, the messages and the parsing of the
/// answers. The screen is in `ai_edit_screen.dart`.
library;

import 'dart:convert';

import '../ai/ai_visibility.dart';
import '../graph/backlinks.dart';
import '../graph/roam_graph.dart';
import 'node_text.dart';
import 'note_editor.dart';

/// How a note of the scope is related to the note "Edit with AI" was
/// opened on.
enum Relation {
  /// The note itself.
  note('the note'),

  /// A note with a link to it.
  linksHere('links here'),

  /// A note it links to.
  linkedFrom('linked from it'),

  /// Both: it links here, and the note links to it.
  both('links here and is linked from it');

  const Relation(this.label);

  /// As the AI and the screen are told.
  final String label;
}

/// One note of the scope, as read when the scope was made.
class ScopeNote {
  ScopeNote({
    required this.node,
    required this.relation,
    required this.base,
    required this.lines,
    required this.hidden,
  });

  final RoamNode node;
  final Relation relation;

  /// The file as read: the change is saved only over this version.
  final NoteVersion base;

  /// Where the node's body is in [base].
  final NodeLines lines;

  /// The body as the AI may see it, with what is hidden from it.
  final HiddenParts hidden;
}

/// The notes an AI edit may see and change.
class Neighbourhood {
  const Neighbourhood(this.notes, {required this.leftOut});

  /// The note first, then the notes that link to it, then the notes it
  /// links to; each file once.
  final List<ScopeNote> notes;

  /// How many notes of the neighbourhood were left out because of the
  /// limit of notes per change set.
  final int leftOut;

  ScopeNote? byId(String id) {
    for (final n in notes) {
      if (n.node.id == id) return n;
    }
    return null;
  }
}

/// Why the neighbourhood could not be made, or an answer is refused.
class NeighbourhoodError implements Exception {
  const NeighbourhoodError(this.message);

  final String message;

  @override
  String toString() => message;
}

final _idLink = RegExp(r'\[\[id:([^\]\[]+?)(?:::[^\]]*)?\](?:\[|\])');

/// The IDs [text] links to with `id:` links, each once, in order.
List<String> linkedIds(String text) => {
      for (final match in _idLink.allMatches(text)) match.group(1)!.trim(),
    }.toList();

/// Whether [node] has notes around it in other files that AI may see,
/// from the index alone: a backlink, or a link from the node (from any
/// heading of the file, for a file's own node).
bool hasNeighbours(RoamNode node, RoamGraph graph, AiVisibility visibility) {
  final visible = visibility.visibleGraph(graph);
  for (final link in visible.links) {
    if (link.dest == node.id) {
      if (visible.nodes[link.source] case final source?
          when source.file != node.file) {
        return true;
      }
    }
    final fromNode =
        node.isFile ? link.file == node.file : link.source == node.id;
    if (fromNode) {
      if (visible.nodes[link.dest] case final target?
          when target.file != node.file) {
        return true;
      }
    }
  }
  return false;
}

/// The neighbourhood of [node]: the note, then its backlinks, then the
/// notes it links to, as far as AI may see them (decision 57), and at
/// most [maxFiles] files.
///
/// A change set has one edit per file, so each file is in it once: for
/// another file, the file's own node when AI may see it (its text holds
/// every heading of the file), else the first node of the file in the
/// scope. Other nodes in the file of [node] are only in the scope through
/// [node]'s own text.
Future<Neighbourhood> neighbourhoodOf(
  RoamNode node, {
  required NoteEditor editor,
  required RoamGraph graph,
  required AiVisibility visibility,
  required int maxFiles,
}) async {
  final visible = visibility.visibleGraph(graph);
  final hiddenIds = visibility.hiddenIds(graph);
  final fileNodes = <String, RoamNode>{
    for (final n in visible.nodes.values)
      if (n.isFile) n.file: n,
  };

  Future<ScopeNote?> read(RoamNode n, Relation relation) async {
    final base = await editor.read(n.file);
    if (base == null) return null;
    // The file may have got a hidden tag since the index was built.
    if (visibility.hides(n) || visibility.hidesInText(n, base.text)) {
      return null;
    }
    final lines = NodeLines.find(base.text, n);
    if (lines == null) return null;
    return ScopeNote(
      node: n,
      relation: relation,
      base: base,
      lines: lines,
      hidden: visibility.splitHidden(lines.body, hiddenIds, numberLinks: true),
    );
  }

  final own = await read(node, Relation.note);
  if (own == null) {
    throw NeighbourhoodError('${node.displayTitle} cannot be read, is no '
        'longer in ${node.file} with its :ID:, or is hidden from AI.');
  }

  // The others, in order, each file once.
  final candidates = <String, (RoamNode, Relation)>{};
  void add(RoamNode n, Relation relation) {
    final chosen = fileNodes[n.file] ?? n;
    if (chosen.file == node.file) return;
    final had = candidates[chosen.file];
    if (had == null) {
      candidates[chosen.file] = (chosen, relation);
    } else if (had.$2 != relation) {
      candidates[chosen.file] = (had.$1, Relation.both);
    }
  }

  for (final backlink in backlinksOf(visible, node.id)) {
    add(backlink.source, Relation.linksHere);
  }
  // From the text as read, so links in the note's headings count too.
  for (final id in linkedIds(own.lines.body)) {
    if (visible.nodes[id] case final target?) add(target, Relation.linkedFrom);
  }

  final notes = [own];
  var leftOut = 0;
  for (final (n, relation) in candidates.values) {
    if (notes.length >= maxFiles) {
      leftOut++;
      continue;
    }
    if (await read(n, relation) case final note?) notes.add(note);
  }
  return Neighbourhood(notes, leftOut: leftOut);
}

/// What the AI is told for the plan, the first step.
const neighbourhoodPlanPrompt = 'You edit notes of an org-roam notes '
    'collection: one note and the notes around it, the notes that link to '
    'it and the notes it links to. You get an instruction and each note '
    'with its ID, title, file and how it is related, and its text in Org '
    'syntax below its title and property drawer.\n\n'
    'First answer only with a plan, as JSON and nothing else: '
    '{"summary": "<one or two sentences on what you will do>", "notes": '
    '[{"id": "<ID of a note you will change>", "change": "<one line on the '
    'change to it>"}]}. List only notes you will change, and only notes '
    'you were given. Do not write the new texts yet: you will be asked for '
    'them after the plan is accepted.';

/// What the AI is told when the plan is accepted.
const neighbourhoodChangePrompt = 'Go ahead. Write the new text of each '
    'note in the plan, and of no other note, in this form and nothing '
    'else:\n\n=== ID: <ID> ===\n<the complete new text of the note>\n'
    '=== end ===\n\n'
    'The text is what comes below the title and property drawer: no title '
    'line, no property drawer of the note. Keep Org syntax, keep every '
    '[[id:...]] link unless the instruction says otherwise, and keep each '
    'line "* (hidden)" (with its stars) exactly as it is, in its place: it '
    'stands for a part you may not see. Keep links with the text '
    '"(hidden N)" as they are. To remove a link but keep its text, write '
    'the link\'s description as plain text.';

/// The first message: the instruction and the notes of [scope].
String neighbourhoodMessage(String instruction, Neighbourhood scope) {
  final out = StringBuffer('Instruction: $instruction\n\n'
      'The notes (${scope.notes.length}):\n');
  for (final (i, n) in scope.notes.indexed) {
    out
      ..write('\n=== Note ${i + 1}: ${n.relation.label} ===\n')
      ..write('ID: ${n.node.id}\n')
      ..write('Title: ${n.node.displayTitle}\n')
      ..write('File: ${n.node.file}\n\n')
      ..write(n.hidden.text)
      ..write(n.hidden.text.endsWith('\n') ? '' : '\n')
      ..write('=== end of note ${i + 1} ===\n');
  }
  return out.toString();
}

/// One note of a plan.
class PlannedChange {
  const PlannedChange(this.note, this.change);

  final ScopeNote note;

  /// The AI's one line on what it will change.
  final String change;
}

/// What the AI will do, before it does it.
class EditPlan {
  const EditPlan(this.summary, this.changes);

  final String summary;
  final List<PlannedChange> changes;

  Set<String> get ids => {for (final c in changes) c.note.node.id};
}

/// The JSON object in [answer], also inside a code fence or after words.
Map<String, Object?>? _jsonObject(String answer) {
  final start = answer.indexOf('{');
  final end = answer.lastIndexOf('}');
  if (start < 0 || end < start) return null;
  try {
    final json = jsonDecode(answer.substring(start, end + 1));
    return json is Map<String, Object?> ? json : null;
  } on FormatException {
    return null;
  }
}

/// The plan in [answer], for the notes of [scope]. Throws
/// [NeighbourhoodError] when it cannot be read, or names a note that is
/// not in the scope.
EditPlan parsePlan(String answer, Neighbourhood scope) {
  final json = _jsonObject(answer);
  final notes = json?['notes'];
  if (json == null || notes is! List) {
    throw const NeighbourhoodError('The AI gave no plan the app can read. '
        'Nothing changed; ask again.');
  }
  final summary = json['summary'];
  final changes = <PlannedChange>[];
  final seen = <String>{};
  for (final item in notes) {
    final id = item is Map ? item['id'] : null;
    if (id is! String || id.trim().isEmpty) {
      throw const NeighbourhoodError('The AI gave a plan with a note '
          'without an ID. Nothing changed; ask again.');
    }
    final note = scope.byId(id.trim());
    if (note == null) {
      throw NeighbourhoodError('The plan names the ID ${id.trim()}, which '
          'is not one of the notes sent. Nothing changed; ask again.');
    }
    if (!seen.add(note.node.id)) continue;
    final change = (item as Map)['change'];
    changes.add(PlannedChange(note, change is String ? change.trim() : ''));
  }
  if (changes.isEmpty) {
    throw NeighbourhoodError(summary is String && summary.trim().isNotEmpty
        ? 'The AI plans no change: ${summary.trim()}'
        : 'The AI plans no change.');
  }
  return EditPlan(summary is String ? summary.trim() : '', changes);
}

final _block = RegExp(
    r'^=== ID: *(.+?) *===[ \t]*\r?\n([\s\S]*?)^=== end ===[ \t]*$',
    multiLine: true);

/// The new texts in [answer], by ID, for the notes of [plan]. Throws
/// [NeighbourhoodError] when there is none, or one is for a note that is
/// not in the plan: then nothing is changed.
Map<String, String> parseNewTexts(String answer, EditPlan plan) {
  final texts = <String, String>{};
  for (final match in _block.allMatches(answer)) {
    final id = match.group(1)!.trim();
    if (!plan.ids.contains(id)) {
      throw NeighbourhoodError('The AI changed the note with the ID $id, '
          'which is not in the plan. Nothing changed; ask again.');
    }
    if (texts.containsKey(id)) {
      throw NeighbourhoodError('The AI gave two texts for the note with '
          'the ID $id. Nothing changed; ask again.');
    }
    texts[id] = match.group(2)!.trim();
  }
  if (texts.isEmpty) {
    throw const NeighbourhoodError('The AI gave no new texts the app can '
        'read. Nothing changed; ask again.');
  }
  return texts;
}
