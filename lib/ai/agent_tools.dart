/// The agent's write tools (#82): the AI creates, edits and links notes
/// itself, in its tool loop, as the org-roam MCP server lets it on the
/// laptop. No confirmation per change; instead, every write keeps the
/// rules of decision 10, and the chat shows a summary afterwards with
/// "Undo all".
library;

import 'dart:convert';
import 'dart:math';

import '../capture/capture_screen.dart';
import '../capture/new_node.dart';
import '../edit/agent_changes.dart';
import '../edit/append.dart';
import '../edit/node_text.dart';
import '../edit/note_editor.dart';
import '../graph/roam_graph.dart';
import 'ai_chat.dart';
import 'ai_tools.dart';
import 'ai_visibility.dart';

const createNodeTool = AiTool(
  'create_node',
  'Create a new note (a file node), as org-roam capture creates one on the '
      'laptop: a new :ID:, #+title and #+filetags. Returns its ID, to link '
      'to it. Write Org mode; link to notes as [[id:<ID>][<title>]] with '
      'IDs the tools gave you.',
  {
    'type': 'object',
    'properties': {
      'title': {'type': 'string', 'description': 'The title, one line'},
      'text': {'type': 'string', 'description': 'The Org text below the title'},
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'File tags, without colons',
      },
    },
    'required': ['title'],
  },
);

const appendToNodeTool = AiTool(
  'append_to_node',
  'Add Org text at the end of an existing note; for a heading node, at the '
      'end of its subtree. Nothing that is there changes.',
  {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'The ID of the note'},
      'text': {'type': 'string', 'description': 'The Org text to add'},
    },
    'required': ['id', 'text'],
  },
);

const editNodeTextTool = AiTool(
  'edit_node_text',
  'Replace a piece of text in an existing note\'s text, below its head. '
      '"old" must occur exactly once in the note\'s text as '
      'org_roam_read_node shows it; read the note first. The head (the '
      'property drawer with the :ID:, the heading line or #+title and '
      '#+filetags) cannot be changed.',
  {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'The ID of the note'},
      'old': {'type': 'string', 'description': 'The text to replace'},
      'new': {'type': 'string', 'description': 'The text to put instead'},
    },
    'required': ['id', 'old', 'new'],
  },
);

const addLinkTool = AiTool(
  'add_link',
  'Link one note to another: adds [[id:<to_id>][<description>]] to the '
      '"See also:" line at the end of the note from_id, or adds that line. '
      'Does nothing if the note links there already.',
  {
    'type': 'object',
    'properties': {
      'from_id': {'type': 'string', 'description': 'The note that links'},
      'to_id': {'type': 'string', 'description': 'The note linked to'},
      'description': {
        'type': 'string',
        'description': 'The link text; the title of to_id by default',
      },
    },
    'required': ['from_id', 'to_id'],
  },
);

const agentTools = [
  createNodeTool,
  appendToNodeTool,
  editNodeTextTool,
  addLinkTool,
];

/// The system prompt in agent mode: as [systemPrompt], but notes are
/// changed with the write tools, which save at once.
final agentSystemPrompt = systemPrompt.replaceFirst(
  'When I ask you to write a note, write it in Org mode with its title on '
      'the first line; I review it before it is saved.',
  'When I ask you to create, change or link notes, do it yourself with the '
      'tools create_node, append_to_node, edit_node_text and add_link, as '
      'many as the task needs; they save at once, and I can undo all '
      'changes of a message afterwards. Read a note before you change it. '
      'If a tool returns an error, read again and retry, or tell me.',
);

/// Runs the agent's write tools on the notes, and records each change.
class AgentWriter {
  AgentWriter({
    required this.writer,
    required this.visibleGraph,
    required this.hiddenIds,
    required this.visibility,
    required this.folder,
    required this.limit,
    this.log = const FileAgentLog(),
    DateTime Function()? now,
    Random? random,
  })  : _now = now ?? DateTime.now,
        _random = random;

  final NoteWriter writer;

  /// The graph the AI may see, as it is now: new notes appear in it once
  /// the folder has been indexed after a write.
  final RoamGraph Function() visibleGraph;
  final Set<String> Function() hiddenIds;
  final AiVisibility visibility;

  /// The chosen folder's URI, for the log.
  final String Function() folder;

  /// The most changes for one message.
  final int limit;
  final AgentLog log;
  final DateTime Function() _now;
  final Random? _random;

  /// The changes of the current message.
  AgentChanges changes = AgentChanges();

  /// The time the last note was created at: file names have seconds, so
  /// two notes made in one second get different names.
  DateTime? _lastCreated;

  /// The note key (folder and path) taken when the note was read.
  String? _folderKey;

  /// Starts recording the changes of a new message; returns them.
  AgentChanges startMessage() => changes = AgentChanges();

  /// The tools this writer runs, by name, for [ChatSession.handlers].
  Map<String, Future<String> Function(ToolCall call)> get handlers => {
        for (final tool in agentTools) tool.name: run,
      };

  /// Runs one tool call; the text goes back to the model. A call that
  /// breaks a rule changes nothing and returns an error the model can act
  /// on.
  Future<String> run(ToolCall call) async {
    final editor = writer.editor;
    if (editor == null) return 'Error: notes cannot be changed here.';
    if (changes.length >= limit) {
      return 'Error: the limit of $limit changes for one message is reached. '
          'Tell me what is left to do; I can ask for it in the next message.';
    }
    try {
      return switch (call.name) {
        'create_node' => await _create(call.input),
        'append_to_node' => await _append(editor, call.input),
        'edit_node_text' => await _edit(editor, call.input),
        'add_link' => await _link(editor, call.input),
        _ => 'Error: unknown tool ${call.name}.',
      };
    } on ToolError catch (e) {
      return 'Error: ${e.message}';
    }
  }

  static String _string(Map<String, Object?> args, String key,
      {bool required = true}) {
    final value = args[key];
    if (value is String && value.trim().isNotEmpty) return value;
    if (!required && (value == null || value is String)) return '';
    throw ToolError('$key is missing.');
  }

  /// The node [id] the AI may see, or a [ToolError].
  RoamNode _node(String id) {
    final node = visibleGraph().nodes[id.trim()];
    if (node == null) {
      throw ToolError('There is no note with the ID $id that you may see.');
    }
    return node;
  }

  /// Refuses links to notes the AI may not see or that do not exist.
  void _checkLinks(String text) {
    final graph = visibleGraph();
    final unknown = [
      for (final id in idLinkTargets(text))
        if (!graph.nodes.containsKey(id)) id,
    ];
    if (unknown.isNotEmpty) {
      throw ToolError('These link targets are no notes you may see: '
          '${unknown.join(', ')}. Use IDs the tools gave you.');
    }
  }

  /// The file of [node] as it is now, checked: still visible, and the node
  /// still in it.
  Future<(NoteVersion, NodeLines)> _read(NoteEditor editor, RoamNode node) async {
    _folderKey = editor.store.historyKey(node.file);
    final base = await editor.read(node.file);
    if (base == null) throw ToolError('${node.file} cannot be read as text.');
    if (visibility.hidesInText(node, base.text)) {
      throw ToolError('There is no note with the ID ${node.id} that you may '
          'see.');
    }
    final lines = NodeLines.find(base.text, node);
    if (lines == null) {
      throw ToolError('The note ${node.id} is no longer in ${node.file} with '
          'its :ID:. Search for it again.');
    }
    return (base, lines);
  }

  Future<String> _create(Map<String, Object?> args) async {
    final title = oneLine(_string(args, 'title'));
    final text = _string(args, 'text', required: false);
    final tagValue = args['tags'];
    final tags = switch (tagValue) {
      List() => [for (final t in tagValue) ...parseTags('$t')],
      String() => parseTags(tagValue),
      _ => <String>[],
    };
    _checkLinks(text);
    if (!sameLockedKeywords('', text)) {
      throw const ToolError('#+title: and #+filetags: lines go in title and '
          'tags, not in the text.');
    }
    if (propertyDrawers(text).isNotEmpty) {
      throw const ToolError('the text may not hold property drawers or '
          ':ID:s; a new note gets its own.');
    }
    final hidden = tags.where(visibility.hiddenTags.contains).toList();
    if (hidden.isNotEmpty) {
      throw ToolError('The tag ${hidden.first} hides a note from you; '
          'leave it out.');
    }
    var time = _now();
    final last = _lastCreated;
    if (last != null && !time.isAfter(last.add(const Duration(seconds: 1)))) {
      time = last.add(const Duration(seconds: 1));
    }
    final id = newOrgId(_random);
    final content = nodeFileText(id: id, title: title, tags: tags, body: text);
    for (var attempt = 0; attempt < 5; attempt++) {
      final name = nodeFileName(time, title);
      final result = await writer.create(name, content);
      switch (result) {
        case Created(:final path) || WrittenNotIndexed(:final path):
          _lastCreated = time;
          await _record('create_node', path, id, title, null, content);
          return 'Created the note "$title" with ID $id ($path).';
        case FileExists():
          time = time.add(const Duration(seconds: 1));
        case NoWriteAccess():
          throw const ToolError('the app may only read the folder. Tell me '
              'to choose the folder again in the app to allow writing.');
        case CreateFailed(:final message):
          throw ToolError('the note could not be written: $message');
      }
    }
    throw const ToolError('no free file name; try again in a moment.');
  }

  Future<String> _append(NoteEditor editor, Map<String, Object?> args) async {
    final node = _node(_string(args, 'id'));
    final addition = _string(args, 'text');
    _checkLinks(addition);
    final (base, lines) = await _read(editor, node);
    if (!sameLockedKeywords('', addition)) {
      throw const ToolError('#+title: and #+filetags: lines cannot be added; '
          'they would change the title or tags.');
    }
    final after = appendToNode(base.text, node, _withNewline(addition, lines));
    if (after == null) throw ToolError('The note ${node.id} was not found.');
    return _save(editor, 'append_to_node', node, base, after,
        'Added the text to "${node.displayTitle}".');
  }

  Future<String> _edit(NoteEditor editor, Map<String, Object?> args) async {
    final node = _node(_string(args, 'id'));
    final oldText = _string(args, 'old');
    final newText = _string(args, 'new', required: false);
    _checkLinks(newText);
    final (base, lines) = await _read(editor, node);
    final body = lines.body;
    // Parts hidden from the AI must stay as they are; it never saw them.
    final shown = visibility.filterText(body, hiddenIds());
    if (shown != body.replaceAll('\r\n', '\n')) {
      throw const ToolError('this note has parts hidden from you, so its '
          'text cannot be replaced; use append_to_node or add_link.');
    }
    final old = _withNewline(oldText, lines), replacement =
        _withNewline(newText, lines);
    final count = old.allMatches(body).length;
    if (count == 0) {
      throw const ToolError('"old" is not in the note\'s text. Read the '
          'note again and copy the text exactly.');
    }
    if (count > 1) {
      throw ToolError('"old" occurs $count times; give more of the text '
          'around it, so it occurs once.');
    }
    final newBody = body.replaceFirst(old, replacement);
    if (!sameLockedKeywords(body, newBody)) {
      throw const ToolError('#+title: and #+filetags: lines stay as they '
          'are: they set the note\'s title and tags.');
    }
    return _save(editor, 'edit_node_text', node, base, lines.withBody(newBody),
        'Changed the text of "${node.displayTitle}".');
  }

  Future<String> _link(NoteEditor editor, Map<String, Object?> args) async {
    final from = _node(_string(args, 'from_id'));
    final to = _node(_string(args, 'to_id'));
    if (from.id == to.id) throw const ToolError('a note cannot link itself.');
    final description = _string(args, 'description', required: false);
    final (base, lines) = await _read(editor, from);
    // The node's own lines: up to its first subheading that is a node of
    // its own, whose links org-roam counts for that node instead.
    final own = _ownEnd(lines);
    final nodeText = lines.lines.sublist(lines.start, own).join('\n');
    if (idLinkTargets(nodeText).contains(to.id)) {
      return '"${from.displayTitle}" links to "${to.displayTitle}" already; '
          'nothing changed.';
    }
    final link = orgLink(
        to.id, description.trim().isEmpty ? to.displayTitle : description);
    // The last "See also:" line of the node gets the link; else a new one.
    var at = -1;
    for (var i = own - 1; i >= lines.bodyStart; i--) {
      if (lines.lines[i].startsWith('See also:')) {
        at = i;
        break;
      }
      if (lines.lines[i].trim().isNotEmpty) break;
    }
    final String after;
    if (at >= 0) {
      final changed = [...lines.lines];
      final line = changed[at].trimRight();
      changed[at] = line == 'See also:' ? '$line $link' : '$line, $link';
      after = changed.join(lines.newline);
    } else {
      // A new line after the last line of the node's own text that is not
      // blank, before any subheading that is a node.
      var end = own;
      while (end > lines.bodyStart && lines.lines[end - 1].trim().isEmpty) {
        end--;
      }
      final changed = [...lines.lines]..insert(end, 'See also: $link');
      // A file that did not end with a newline gets one.
      if (end == lines.lines.length) changed.add('');
      after = changed.join(lines.newline);
    }
    return _save(editor, 'add_link', from, base, after,
        'Linked "${from.displayTitle}" to "${to.displayTitle}".');
  }

  /// The end of the node's own text in [lines]: the first heading below
  /// its head whose property drawer has an `:ID:`, or the node's end.
  static int _ownEnd(NodeLines lines) {
    final all = lines.lines;
    final drawer = RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
    final planning =
        RegExp(r'^[ \t]*(SCHEDULED|DEADLINE|CLOSED):', caseSensitive: false);
    final id = RegExp(r'^[ \t]*:ID:[ \t]+\S', caseSensitive: false);
    final end = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);
    for (var i = lines.bodyStart; i < lines.end; i++) {
      if (!headingLine.hasMatch(all[i])) continue;
      var j = i + 1;
      if (j < all.length && planning.hasMatch(all[j])) j++;
      if (j >= all.length || !drawer.hasMatch(all[j])) continue;
      for (var k = j + 1; k < all.length && !end.hasMatch(all[k]); k++) {
        if (id.hasMatch(all[k])) return i;
      }
    }
    return lines.end;
  }

  /// [text] with the line endings of the file of [lines].
  static String _withNewline(String text, NodeLines lines) =>
      lines.newline == '\n'
          ? text.replaceAll('\r\n', '\n')
          : text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

  Future<String> _save(NoteEditor editor, String tool, RoamNode node,
      NoteVersion base, String after, String done) async {
    // Another folder may have been chosen since the note was read: the
    // same path there is another note.
    if (editor.store.historyKey(node.file) != _folderKey) {
      throw const ToolError('another folder was opened in the app; nothing '
          'was written. Stop here.');
    }
    final result = await editor.save(node.file, base, after);
    switch (result) {
      case Saved() || SavedNotIndexed():
        await _record(tool, node.file, node.id, node.displayTitle, base.text,
            after);
        return result is SavedNotIndexed
            ? '$done The graph shows it after the next scan.'
            : done;
      case NothingToSave():
        return 'Nothing changed: the text is already so.';
      case ChangedMeanwhile():
        throw ToolError('${node.file} changed since it was read (on the '
            'laptop or through Syncthing); nothing was written. Read the '
            'note again and retry.');
      case NoteGone():
        throw ToolError('${node.file} is no longer in the folder.');
      case LockedPartChanged():
        throw const ToolError('the change would alter an :ID: or a property '
            'drawer, which stay as they are; nothing was written.');
      case NoWriteAccessToEdit():
        throw const ToolError('the app may only read the folder. Tell me to '
            'choose the folder again in the app to allow writing.');
      case SaveFailed(:final message):
        throw ToolError('the note could not be saved: $message');
    }
  }

  Future<void> _record(String tool, String path, String id, String title,
      String? before, String after) async {
    int links(String? text) =>
        text == null ? 0 : RegExp(r'\[\[id:').allMatches(text).length;
    changes.changes.add(AgentChange(
      tool: tool,
      path: path,
      noteKey: writer.editor?.store.historyKey(path) ?? path,
      nodeId: id,
      title: title,
      before: before,
      after: after,
      linksAdded: (links(after) - links(before)).clamp(0, 1 << 30),
    ));
    await log.record(AgentLogEntry(
      time: _now(),
      folder: folder(),
      path: path,
      tool: tool,
      oldHash: before == null ? null : contentHash(utf8.encode(before)),
      newHash: contentHash(utf8.encode(after)),
    ));
  }
}

