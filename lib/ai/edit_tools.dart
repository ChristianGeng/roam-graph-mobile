/// The chat's tool for proposing an edit of an existing note (#39). The
/// tool only records the proposal; the user reviews the diff (#38), and
/// only then is it saved (#35). The AI never writes.
library;

import '../edit/edit_proposal.dart';
import '../graph/roam_graph.dart';
import 'ai_tools.dart';
import 'note_language.dart';

const proposeEditTool = AiTool(
  'propose_edit',
  'Propose a change to one existing note. Nothing is saved by this tool: '
      'I review the change as a diff in the app and decide. Use it only '
      'when I ask you to change a note. mode "append" adds text at the end '
      'of the note (for a heading node, at the end of its subtree). mode '
      '"replace" replaces the note\'s text below its head; the head (the '
      'heading line or the #+title and #+filetags lines, and the property '
      'drawer with the :ID:) stays as it is and must not be in the text. '
      'Read the note with org_roam_read_node first. Write Org mode, and '
      'link to notes as [[id:<ID>][<title>]] with IDs the tools gave you.',
  {
    'type': 'object',
    'properties': {
      'node_id': {'type': 'string', 'description': 'The ID of the note'},
      'mode': {
        'type': 'string',
        'enum': ['append', 'replace'],
        'description': 'append: add at the end; replace: the new text '
            'below the head',
      },
      'text': {'type': 'string', 'description': 'The Org text'},
      'reason': {
        'type': 'string',
        'description': 'One sentence: what the change does and why',
      },
    },
    'required': ['node_id', 'mode', 'text'],
  },
);

/// The proposal in [args], for a node of [visible], the graph without the
/// notes hidden from AI. Throws [ToolError] for a call that cannot be a
/// proposal.
EditProposal proposalFrom(Map<String, Object?> args, RoamGraph visible) {
  final id = args['node_id'];
  if (id is! String || id.trim().isEmpty) {
    throw const ToolError('node_id is missing.');
  }
  if (!visible.nodes.containsKey(id.trim())) {
    throw ToolError('There is no note with the ID $id that you may see.');
  }
  final mode = switch (args['mode']) {
    'append' => EditMode.append,
    'replace' => EditMode.replace,
    _ => throw const ToolError('mode must be "append" or "replace".'),
  };
  final text = args['text'];
  if (text is! String || text.trim().isEmpty) {
    throw const ToolError('text is missing.');
  }
  if (!sameLanguageLines('', text)) {
    throw const ToolError('the text may not hold a #+language: line: an '
        'edit keeps the note\'s language. I set it with "Set language…" '
        'in search.');
  }
  final reason = args['reason'];
  return EditProposal(
    nodeId: id.trim(),
    mode: mode,
    text: text,
    reason: reason is String ? reason.trim() : '',
  );
}

/// The change-set tool (#76): edits to several notes at once, reviewed
/// together. [maxFiles] is the limit the user set; the model is told it.
AiTool proposeEditsTool(int maxFiles) => AiTool(
      'propose_edits',
      'Propose edits to several existing notes at once, for example links '
          'between related notes or a "See also" line in each. Nothing is '
          'saved by this tool: I review every file\'s diff in the app, '
          'accept or reject each, and save. One edit per note, at most '
          '$maxFiles notes. Each edit works as in propose_edit: mode '
          '"append" adds text at the end of the note, mode "replace" '
          'replaces its text below its head. Read the notes first. Link to '
          'notes as [[id:<ID>][<title>]] with IDs the tools gave you.',
      {
        'type': 'object',
        'properties': {
          'summary': {
            'type': 'string',
            'description': 'One sentence: what the set does',
          },
          'edits': {
            'type': 'array',
            'maxItems': maxFiles,
            'items': proposeEditTool.parameters,
          },
        },
        'required': ['edits'],
      },
    );

/// The proposals in a `propose_edits` call; each checked as in
/// [proposalFrom]. Throws [ToolError].
List<EditProposal> proposalsFrom(Map<String, Object?> args, RoamGraph visible) {
  final edits = args['edits'];
  if (edits is! List || edits.isEmpty) {
    throw const ToolError('edits is missing or empty.');
  }
  return [
    for (final (i, edit) in edits.indexed)
      if (edit is Map<String, Object?>)
        _numbered(i, () => proposalFrom(edit, visible))
      else
        throw ToolError('edits[$i] is not an object.'),
  ];
}

EditProposal _numbered(int i, EditProposal Function() parse) {
  try {
    return parse();
  } on ToolError catch (e) {
    throw ToolError('edits[$i]: ${e.message}');
  }
}
