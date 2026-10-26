/// The agent's write tools (#82): the AI creates, edits and links notes
/// itself, in its tool loop, as the org-roam MCP server lets it on the
/// laptop. No confirmation per change; instead, every write keeps the
/// rules of decision 10, and the chat shows a summary afterwards with
/// "Undo all".
library;

import 'dart:math';

import '../capture/capture_screen.dart';
import '../capture/new_node.dart';
import '../edit/agent_changes.dart';
import '../edit/append.dart';
import '../edit/delete_node.dart';
import '../edit/node_meta.dart';
import '../edit/node_text.dart';
import '../edit/image_screen.dart';
import '../edit/note_editor.dart';
import '../edit/see_also.dart';
import '../graph/roam_graph.dart';
import 'ai_chat.dart';
import 'ai_images.dart';
import 'ai_providers.dart';
import 'ai_tools.dart';
import 'ai_visibility.dart';
import 'note_language.dart';

const createNodeTool = AiTool(
  'create_node',
  'Create a new note (a file node), as org-roam capture creates one on the '
      'laptop: a new :ID:, #+title and #+filetags, and #+language: with '
      'the language the note is written in. Returns its ID, to link to it. '
      'Write Org mode; link to notes as [[id:<ID>][<title>]] with IDs the '
      'tools gave you.',
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
      'language': {
        'type': 'string',
        'description': 'The language code of the note, such as de or en, '
            'only when my request asks for a language; otherwise the app '
            'writes the language the system prompt names',
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

const deleteNodeTool = AiTool(
  'delete_node',
  'Delete a note, only when I ask you to delete it. A file node: its file '
      'is deleted, with the headings in it. A heading node: the heading and '
      'its subtree are removed from its file. Links to the deleted notes in '
      'other notes become their link text, so no link points nowhere. Each '
      'of these is a change I can undo.',
  {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'The ID of the note to delete'},
    },
    'required': ['id'],
  },
);

const renameNodeTool = AiTool(
  'rename_node',
  'Change a note\'s title: a file node\'s #+title, a heading node\'s '
      'heading text (its TODO keyword, priority and tags stay). The :ID: and '
      'the file name stay, so every link to it still works.',
  {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'The ID of the note'},
      'title': {'type': 'string', 'description': 'The new title, one line'},
    },
    'required': ['id', 'title'],
  },
);

const setTagsTool = AiTool(
  'set_tags',
  'Set a note\'s own tags: a file node\'s #+filetags, a heading node\'s '
      'tags. Give the whole list; an empty list removes them. Tags are '
      'letters, digits and _@#%, without colons.',
  {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'The ID of the note'},
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': ['id', 'tags'],
  },
);

const setAliasesTool = AiTool(
  'set_aliases',
  'Set a note\'s aliases (ROAM_ALIASES), the other names it is found by. '
      'Give the whole list; an empty list removes them.',
  {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'The ID of the note'},
      'aliases': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': ['id', 'aliases'],
  },
);

const setLanguageTool = AiTool(
  'set_language',
  'Set the #+language: of a note\'s file to a language code, such as de '
      'or en; for a heading node, of the file it is in. Only when I ask for '
      'it. It does not translate the text.',
  {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'The ID of the note'},
      'language': {'type': 'string', 'description': 'The language code'},
    },
    'required': ['id', 'language'],
  },
);

const agentTools = [
  createNodeTool,
  appendToNodeTool,
  editNodeTextTool,
  addLinkTool,
  deleteNodeTool,
  renameNodeTool,
  setTagsTool,
  setAliasesTool,
  setLanguageTool,
];

/// One image model for `create_image` (#183): how to ask it, and what
/// the tool says about it.
class ImageModel {
  const ImageModel(
      {required this.make, required this.name, this.maxPrompt = 4000});

  /// Asks the image model; throws [AiError].
  final Future<MadeImage> Function(String prompt) make;

  /// Which model makes the images, and where.
  final String name;

  /// The longest prompt the provider takes.
  final int maxPrompt;
}

/// What `create_image` needs (#129): the image model of "Images with:"
/// (#127), said in words for the tool's description, and where images go;
/// and the one of "Infographics with:" (#183).
class ImageMaker {
  const ImageMaker({
    required this.make,
    required this.model,
    required this.folder,
    this.maxPrompt = 4000,
    this.limit = 1,
    this.infographics,
    this.noIllustrations,
  });

  /// The image model of "Infographics with:" (#183); null when it is the
  /// same as for illustrations.
  final ImageModel? infographics;

  /// Why "Images with:" can make no illustration now, with only
  /// "Infographics with:" set up (#183); null when it can.
  final String? noIllustrations;

  /// The image model for [kind].
  ImageModel forKind(ImageKind kind) =>
      (kind == ImageKind.infographic ? infographics : null) ??
      ImageModel(make: make, name: model, maxPrompt: maxPrompt);

  /// Asks the image model; throws [AiError].
  final Future<MadeImage> Function(String prompt) make;

  /// Which model makes the images, and where, for example
  /// "mistral-medium-latest at Mistral, in the EU".
  final String model;

  /// The image folder, relative to `roam/` (`.` is `roam/`), from the
  /// settings (#112).
  final String folder;

  /// The longest prompt the provider takes.
  final int maxPrompt;

  /// The most images for one message.
  final int limit;
}

/// The longest prompt for images asked in [api]: DashScope takes about
/// 800 characters; the others far more.
int maxImagePrompt(ImageApi api) => api == ImageApi.dashscope ? 800 : 4000;

/// `create_image` (#129), described with the image models in use, so the
/// model knows what it asks: one for illustrations and one for
/// infographics (#183).
AiTool createImageTool(ImageMaker maker) {
  final illustration = maker.forKind(ImageKind.illustration);
  final infographic = maker.forKind(ImageKind.infographic);
  return AiTool(
    'create_image',
    'Make an image with an image model and add it to a note, below its '
        'text, with a caption. ${switch (maker.noIllustrations) {
          final why? => 'kind "illustration" cannot be made now: $why. '
              'kind "infographic" is drawn by ${infographic.name}, at most '
              '${infographic.maxPrompt} characters of prompt.',
          null => 'kind "illustration" (the default) is drawn by '
              '${illustration.name}, at most ${illustration.maxPrompt} '
              'characters of prompt; kind "infographic" by '
              '${infographic.name}, at most ${infographic.maxPrompt}.',
        }} Use "infographic" for anything '
        'with numbers, labels or text. Only the prompt goes to the image '
        'model, never the notes, and it knows nothing after its training: '
        'do the research first, with the other tools, then put every fact, '
        'number, year and label the image needs into the prompt, in '
        'English. For an infographic, write the prompt as a layout brief: '
        'the title, the exact values with units and dates, the chart form, '
        'the labels, the colours, and a source line naming the source and '
        'the date the data was read. Give the same values in data: they go '
        'into the note below the image, as a table with the source. No '
        'links and no running text in the prompt. For an illustration, '
        'keep labels few and short, and numbers few and large. At most '
        '${maker.limit} ${maker.limit == 1 ? 'image' : 'images'} for one '
        'message, so use it only when I ask for an image, and only once '
        'unless the image is wrong. You are shown the image if you can '
        'see images: check it against the prompt. If a word or number '
        'is wrong and the limit allows, make it again for the same note: '
        'the new image replaces the one of this message; else tell me '
        'what is wrong.',
    {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'The ID of the note the image is for',
        },
        'kind': {
          'type': 'string',
          'enum': [for (final kind in ImageKind.values) kind.name],
          'description': '"infographic" for numbers, labels or text; else '
              '"illustration" (the default)',
        },
        'prompt': {
          'type': 'string',
          'description': 'What the image shows, with all facts and labels; '
              'for an infographic a layout brief, without links',
        },
        'caption': {
          'type': 'string',
          'description': 'A short caption for the note, one line, in the '
              'language of the note',
        },
        'data': {
          'type': 'object',
          'description': 'Only for an infographic, and needed there: the '
              'values it shows, written into the note below the image',
          'properties': {
            'columns': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'The column headings, with units',
            },
            'rows': {
              'type': 'array',
              'items': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'description': 'The rows, one value per column, as written '
                  'in the picture',
            },
            'source': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
                'url': {
                  'type': 'string',
                  'description': 'https://..., or id:<ID> for a note',
                },
              },
              'required': ['name', 'url'],
            },
            'retrieved': {
              'type': 'string',
              'description': 'The date the data was read, YYYY-MM-DD',
            },
          },
          'required': ['columns', 'rows', 'source', 'retrieved'],
        },
      },
      'required': ['id', 'prompt', 'caption'],
    },
  );
}

/// The values an infographic shows (#183), written into the note below
/// its image, so they can be checked and updated later.
class InfographicData {
  const InfographicData({
    required this.columns,
    required this.rows,
    required this.sourceName,
    required this.sourceUrl,
    required this.retrieved,
  });

  /// The most columns and rows: a small table.
  static const maxColumns = 12, maxRows = 60;

  final List<String> columns;
  final List<List<String>> rows;
  final String sourceName;

  /// `https://…`, `http://…` or `id:<ID>`.
  final String sourceUrl;

  /// The date the data was read, `YYYY-MM-DD`.
  final String retrieved;

  /// [json], the tool's `data`, checked; a [ToolError] says what is wrong.
  factory InfographicData.from(Object? json) {
    if (json is! Map) {
      throw const ToolError('an infographic needs data: columns, rows, '
          'source (name and url) and retrieved.');
    }
    String cell(Object? value) => switch (value) {
          final String text => _cell(text),
          final num number => '$number',
          null => '',
          _ => throw const ToolError('data values must be text or numbers.'),
        };
    final columns = json['columns'];
    if (columns is! List || columns.isEmpty) {
      throw const ToolError('data.columns is missing.');
    }
    if (columns.length > maxColumns) {
      throw const ToolError(
          'data has more than $maxColumns columns; keep the table small.');
    }
    final rows = json['rows'];
    if (rows is! List || rows.isEmpty) {
      throw const ToolError('data.rows is missing.');
    }
    if (rows.length > maxRows) {
      throw const ToolError(
          'data has more than $maxRows rows; keep the table small.');
    }
    final table = <List<String>>[];
    for (final row in rows) {
      if (row is! List) {
        throw const ToolError('each row in data.rows must be a list.');
      }
      if (row.length > columns.length) {
        throw const ToolError('a row in data.rows has more values than '
            'data.columns has columns.');
      }
      table.add([
        for (var i = 0; i < columns.length; i++)
          i < row.length ? cell(row[i]) : '',
      ]);
    }
    final source = json['source'];
    final name = source is Map && source['name'] is String
        ? _cell(source['name'] as String)
        : '';
    final url = source is Map && source['url'] is String
        ? (source['url'] as String).trim()
        : '';
    if (name.isEmpty || url.isEmpty) {
      throw const ToolError('data.source needs a name and a url.');
    }
    if (!RegExp(r'^(https?://|id:)[^\s\[\]]+$').hasMatch(url)) {
      throw const ToolError('data.source.url must be an https:// link, or '
          'id:<ID> for a note.');
    }
    final retrieved =
        json['retrieved'] is String ? (json['retrieved'] as String).trim() : '';
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(retrieved)) {
      throw const ToolError('data.retrieved must be the date the data was '
          'read, as YYYY-MM-DD.');
    }
    return InfographicData(
      columns: [for (final c in columns) cell(c)],
      rows: table,
      sourceName: name,
      sourceUrl: url,
      retrieved: retrieved,
    );
  }

  /// One table cell: one line, without the column bar.
  static String _cell(String text) => oneLine(text).replaceAll('|', '/');

  /// The Org table, aligned as Org aligns it, and the source line.
  String get org {
    final widths = [
      for (var i = 0; i < columns.length; i++)
        [columns[i], for (final row in rows) row[i]]
            .map((c) => c.runes.length)
            .reduce(max),
    ];
    String line(List<String> cells) => '| ${[
          for (var i = 0; i < cells.length; i++)
            cells[i] + ' ' * (widths[i] - cells[i].runes.length),
        ].join(' | ')} |';
    return [
      line(columns),
      '|${[for (final w in widths) '-' * (w + 2)].join('+')}|',
      for (final row in rows) line(row),
      'Source: [[$sourceUrl][${orgLinkDescription(sourceName)}]], '
          'retrieved $retrieved',
    ].join('\n');
  }
}

/// [system] with today's date, so "the last 5 years" is counted from
/// today, not from the end of the model's training (#129).
String withToday(String system, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '$system Today is ${now.year}-${two(now.month)}-${two(now.day)}.';
}

/// The system prompt in agent mode: as [systemPrompt], but notes are
/// changed with the write tools, which save at once.
final agentSystemPrompt = systemPrompt.replaceFirst(
  'When I ask you to write a note, write it in Org mode with its title on '
      'the first line; I review it before it is saved.',
  'When I ask you to create, change or link notes, do it yourself with the '
      'tools create_node, append_to_node, edit_node_text and add_link, as '
      'many as the task needs, and rename_node, set_tags and set_aliases '
      'for a note\'s title, tags and aliases, and set_language for its '
      '#+language: when I ask; they save at once, and I can '
      'undo all '
      'changes of a message afterwards. Delete notes with delete_node only '
      'when I ask you to delete them. Read a note before you change it. '
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
    this.images,
    this.language = defaultNoteLanguage,
    DateTime Function()? now,
    Random? random,
  })  : _now = now ?? DateTime.now,
        _random = random;

  /// The image model for `create_image`; null where there is none (#129).
  final ImageMaker? images;

  /// The language code `create_node` writes when the request names none
  /// (#172): decided by rules 2 to 4 when the chat starts.
  final String language;

  /// The images made for the current message, by tool call, to show the
  /// model; and the block each note got, to replace with a better one.
  final _imagesByCall = <String, ToolImage>{};
  final _imageBlocks = <String, String>{};
  int _imageCount = 0;

  /// The infographics made for each note in the current message (#183):
  /// a second one corrects the first; there is no third.
  final _infographicTries = <String, int>{};

  /// The image the call [call] made, for [ChatSession.toolImage].
  ToolImage? imageFor(ToolCall call) => _imagesByCall[call.id];

  /// The tools this writer offers: [agentTools], and `create_image` where
  /// there is an image model.
  List<AiTool> get tools =>
      [...agentTools, if (images case final maker?) createImageTool(maker)];

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

  /// Starts recording the changes of a new message; returns them. The
  /// log groups them by the message's ID and shows [prompt]'s first words
  /// (#99).
  AgentChanges startMessage({String prompt = ''}) {
    final time = _now();
    final words = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    _imagesByCall.clear();
    _imageBlocks.clear();
    _imageCount = 0;
    _infographicTries.clear();
    return changes = AgentChanges(
      messageId: '${time.microsecondsSinceEpoch.toRadixString(36)}-'
          '${(_random ?? Random()).nextInt(1 << 30).toRadixString(36)}',
      prompt: words.length <= 80 ? words : '${words.substring(0, 79)}…',
      time: time,
    );
  }

  /// The tools this writer runs, by name, for [ChatSession.handlers].
  Map<String, Future<String> Function(ToolCall call)> get handlers => {
        for (final tool in tools) tool.name: run,
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
        'delete_node' => await _delete(editor, call.input),
        'rename_node' ||
        'set_tags' ||
        'set_aliases' =>
          await _meta(editor, call.name, call.input),
        'set_language' => await _setLanguage(editor, call.input),
        'create_image' => await _image(editor, call),
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
    if (!sameLanguageLines('', text)) {
      throw const ToolError('a #+language: line goes in language, not in '
          'the text.');
    }
    final asked = _string(args, 'language', required: false);
    final code = asked.isEmpty ? language : languageCode(asked);
    if (code == null) {
      throw ToolError('$asked is no language code; give one such as de or '
          'en.');
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
    final content = nodeFileText(
        id: id, title: title, tags: tags, body: text, language: code);
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
    if (!sameLanguageLines('', addition)) {
      throw const ToolError('a #+language: line cannot be added here; use '
          'set_language when I ask for a language.');
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
    final after = withSeeAlso(lines, to.id,
        orgLink(to.id, description.trim().isEmpty ? to.displayTitle : description));
    if (after == null) {
      return '"${from.displayTitle}" links to "${to.displayTitle}" already; '
          'nothing changed.';
    }
    return _save(editor, 'add_link', from, base, after,
        'Linked "${from.displayTitle}" to "${to.displayTitle}".');
  }

  /// `create_image` (#129): the image model draws the prompt; the image
  /// goes into the image folder and, with its prompt and caption, below
  /// the note's text. A second image for the same note in one message
  /// replaces the first in the note.
  Future<String> _image(NoteEditor editor, ToolCall call) async {
    final maker = images;
    final createFile = writer.createFile;
    if (maker == null || createFile == null) {
      throw const ToolError('no image model is set up; tell me to choose '
          'one under "Images with:" in AI settings.');
    }
    final args = call.input;
    final node = _node(_string(args, 'id'));
    final kind = switch (args['kind']) {
      null || '' || 'illustration' => ImageKind.illustration,
      'infographic' => ImageKind.infographic,
      _ => throw const ToolError(
          'kind must be "illustration" or "infographic".'),
    };
    if (kind == ImageKind.illustration) {
      if (maker.noIllustrations case final why?) {
        throw ToolError('an illustration cannot be made now: $why. Only '
            'kind "infographic" can be made.');
      }
    }
    final model = maker.forKind(kind);
    final prompt = _string(args, 'prompt').trim();
    final caption = oneLine(_string(args, 'caption', required: false));
    if (prompt.length > model.maxPrompt) {
      throw ToolError('the prompt has ${prompt.length} characters; the image '
          'model takes at most ${model.maxPrompt}. Shorten it.');
    }
    final infographic = kind == ImageKind.infographic;
    final data = infographic ? InfographicData.from(args['data']) : null;
    if (data != null) {
      if (RegExp(r'https?://|www\.', caseSensitive: false).hasMatch(prompt)) {
        throw const ToolError('the prompt has a link. Name the source and '
            'the date in the prompt without its link; the link goes into '
            'data.source.url.');
      }
      if (data.sourceUrl.startsWith('id:')) {
        _checkLinks('[[${data.sourceUrl}]]');
      }
      if ((_infographicTries[node.id] ?? 0) >= 2) {
        throw const ToolError('this note\'s infographic was made twice in '
            'this message already. Do not make it again; tell me what is '
            'still wrong in it.');
      }
    }
    if (_imageCount >= maker.limit) {
      throw ToolError('the limit of ${maker.limit} '
          '${maker.limit == 1 ? 'image' : 'images'} for one message is '
          'reached. Tell me what is wrong with the image instead; I can ask '
          'for another in the next message.');
    }
    // The note must be one the AI may see, before anything is made.
    await _read(editor, node);
    final MadeImage image;
    try {
      image = await model.make(prompt);
    } on AiError catch (e) {
      throw ToolError('the image model failed: ${e.message}');
    }
    // Counted once made: a failed request costs nothing.
    _imageCount++;
    // A free name: a second later if the name is taken.
    var time = _now();
    String? path;
    for (var attempt = 0; attempt < 5 && path == null; attempt++) {
      final candidate =
          imagePath(maker.folder, time, node.displayTitle, image.extension);
      switch (await createFile(candidate, image.bytes)) {
        case Created() || WrittenNotIndexed():
          path = candidate;
        case FileExists():
          time = time.add(const Duration(seconds: 1));
        case NoWriteAccess():
          throw const ToolError('the app may only read the folder. Tell me '
              'to choose the folder again in the app to allow writing.');
        case CreateFailed(:final message):
          throw ToolError('the image could not be written: $message');
      }
    }
    if (path == null) throw const ToolError('no free file name for the image.');
    final block = '# image prompt: ${oneLine(prompt)}\n'
        '${imageAddition(caption.isEmpty ? oneLine(prompt) : caption, relativeLink(node.file, path))}'
        '${data == null ? '' : '\n${data.org}\n'}';
    // The note as it is now: the image took a while.
    final (base, lines) = await _read(editor, node);
    final earlier = _imageBlocks[node.id];
    final body = lines.body;
    final String after;
    final String done;
    final old = earlier == null ? null : _withNewline(earlier.trimRight(), lines);
    if (old != null && old.allMatches(body).length == 1) {
      after = lines.withBody(
          body.replaceFirst(old, _withNewline(block.trimRight(), lines)));
      done = 'Replaced the image of this message in "${node.displayTitle}"';
    } else {
      after = lines.withAddition(_withNewline(block, lines));
      done = 'Added the image to "${node.displayTitle}"';
    }
    final result = await _save(editor, 'create_image', node, base, after,
        '$done, as roam/$path, with the caption "${caption.isEmpty ? oneLine(prompt) : caption}".');
    _imageBlocks[node.id] = block;
    _imagesByCall[call.id] = ToolImage(image.bytes, switch (image.extension) {
      'jpg' => 'image/jpeg',
      'webp' => 'image/webp',
      _ => 'image/png',
    });
    if (data == null) return '$result Made by ${model.name}.';
    final tries =
        _infographicTries[node.id] = (_infographicTries[node.id] ?? 0) + 1;
    final check = 'Made by ${model.name}. The data table and the source '
        'line are in the note below the image. Compare every number and '
        'label in the picture with data.';
    if (tries >= 2) {
      return '$result $check This was the corrected image: do not make it '
          'again; tell me what is still wrong, if anything.';
    }
    if (_imageCount >= maker.limit) {
      return '$result $check If one is wrong, tell me what is wrong: the '
          'limit of ${maker.limit} '
          '${maker.limit == 1 ? 'image' : 'images'} for this message is '
          'reached.';
    }
    return '$result $check If one is wrong, make the image once more for '
        'this note, with kind "infographic", the same data and a corrected '
        'brief; it replaces this one. After that, tell me what is still '
        'wrong instead of trying again.';
  }

  /// `rename_node`, `set_tags` and `set_aliases` (#97): the node's head,
  /// and nothing else of it.
  Future<String> _meta(
      NoteEditor editor, String tool, Map<String, Object?> args) async {
    final node = _node(_string(args, 'id'));
    List<String> list(String key) {
      final value = args[key];
      if (value is List) return [for (final v in value) '$v'.trim()];
      if (value is String) return [value.trim()];
      throw ToolError('$key is missing.');
    }

    final (base, _) = await _read(editor, node);
    final current = readMeta(base.text, node);
    if (current == null) {
      throw ToolError('The note ${node.id} was not found in ${node.file}.');
    }
    final meta = switch (tool) {
      'rename_node' => NodeMeta(
          title: oneLine(_string(args, 'title')),
          tags: current.tags,
          aliases: current.aliases),
      'set_tags' => NodeMeta(
          title: current.title,
          tags: [
            for (final t in list('tags'))
              if (t.isNotEmpty) t.replaceAll(':', ''),
          ],
          aliases: current.aliases),
      _ => NodeMeta(
          title: current.title,
          tags: current.tags,
          aliases: [
            for (final a in list('aliases'))
              if (a.isNotEmpty) a,
          ]),
    };
    final hidden = meta.tags.where(visibility.hiddenTags.contains).toList();
    if (hidden.isNotEmpty) {
      throw ToolError('The tag ${hidden.first} hides a note from you; leave '
          'it out.');
    }
    final String after;
    try {
      after = withMeta(base.text, node, meta);
    } on MetaError catch (e) {
      throw ToolError(e.message);
    }
    final what = switch (tool) {
      'rename_node' => 'Renamed "${node.displayTitle}" to "${meta.title}".',
      'set_tags' => meta.tags.isEmpty
          ? 'Removed the tags of "${node.displayTitle}".'
          : 'Set the tags of "${node.displayTitle}": ${meta.tags.join(' ')}.',
      _ => meta.aliases.isEmpty
          ? 'Removed the aliases of "${node.displayTitle}".'
          : 'Set the aliases of "${node.displayTitle}": '
              '${meta.aliases.join(', ')}.',
    };
    return _save(editor, tool, node, base, after, what,
        aliasesMayChange: true);
  }

  /// `set_language` (#172): adds or replaces the `#+language:` of the
  /// node's file, nothing else.
  Future<String> _setLanguage(
      NoteEditor editor, Map<String, Object?> args) async {
    final node = _node(_string(args, 'id'));
    final asked = _string(args, 'language');
    final code = languageCode(asked);
    if (code == null) {
      throw ToolError('$asked is no language code; give one such as de or '
          'en.');
    }
    final (base, _) = await _read(editor, node);
    final after = withLanguage(base.text, code);
    final file = node.isFile ? '"${node.displayTitle}"' : node.file;
    return _save(editor, 'set_language', node, base, after,
        'Set the language of $file to $code.');
  }

  /// The shared delete keeps the AI's visibility checks and limit (#171).
  Future<String> _delete(NoteEditor editor, Map<String, Object?> args) async {
    final node = _node(_string(args, 'id'));
    final deleter = NodeDeleter(
      editor: editor,
      now: _now,
      read: (node) async {
        try {
          return await _read(editor, node);
        } on ToolError catch (e) {
          throw DeleteError(e.message);
        }
      },
      save: (node, base, after, removed) async {
        try {
          await _save(editor, 'delete_node', node, base, after, '',
              removed: removed);
        } on ToolError catch (e) {
          throw DeleteError(e.message);
        }
      },
      record: (node, before, after, removed, key) => _record('delete_node',
          node.file, node.id, node.displayTitle, before, after, removed: removed, noteKey: key),
      canChange: () => changes.length < limit,
      bracketLinksOnly: true,
      checkGoing: (going) {
        final normal = going.replaceAll('\r\n', '\n');
        final hiddenNow = hiddenIds();
        final idInGoing = RegExp(r'^[ \t]*:ID:[ \t]+(\S+)[ \t]*$',
            multiLine: true, caseSensitive: false);
        if (idInGoing.allMatches(normal).any((m) => hiddenNow.contains(m[1])) ||
            visibility.filterText(normal, const {}) != normal) {
          throw const DeleteError('that note has parts hidden from you, so it '
              'cannot be deleted here. Tell me to delete it myself.');
        }
      },
    );
    try {
      final plan = await deleter.prepare(visibleGraph(), [node]);
      final report = await deleter.apply(plan, stopOnError: true);
      return [
        node.isFile
            ? 'Deleted the note "${node.displayTitle}" (${node.file}).'
            : 'Deleted the heading "${node.displayTitle}" with its subtree.',
        if (report.cleaned.isNotEmpty)
          'Links to it in ${report.cleaned.length} '
              '${report.cleaned.length == 1 ? 'note' : 'notes'} became their text: '
              '${report.cleaned.join(', ')}.',
        if (report.left.isNotEmpty)
          'Links to it in these notes could not be changed and point nowhere '
              'now: ${report.left.join(', ')}.',
      ].join(' ');
    } on DeleteError catch (e) {
      throw ToolError(e.message);
    }
  }

  /// [text] with the line endings of the file of [lines].
  static String _withNewline(String text, NodeLines lines) =>
      lines.newline == '\n'
          ? text.replaceAll('\r\n', '\n')
          : text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

  Future<String> _save(NoteEditor editor, String tool, RoamNode node,
      NoteVersion base, String after, String done,
      {String removed = '', bool aliasesMayChange = false}) async {
    // Another folder may have been chosen since the note was read: the
    // same path there is another note.
    final key = _folderKey;
    if (editor.store.historyKey(node.file) != key) {
      throw const ToolError('another folder was opened in the app; nothing '
          'was written. Stop here.');
    }
    if (tool != 'set_language' &&
        tool != 'delete_node' &&
        !sameLanguageLines(base.text, after)) {
      throw const ToolError('#+language: lines stay as they are; use '
          'set_language when I ask for a language. Nothing was written.');
    }
    final result = await editor.save(node.file, base, after,
        removed: removed, aliasesMayChange: aliasesMayChange);
    switch (result) {
      case Saved() || SavedNotIndexed():
        await _record(tool, node.file, node.id, node.displayTitle, base.text,
            after, removed: removed, noteKey: key);
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
      String? before, String? after, {String removed = '', String? noteKey}) async {
    int links(String? text) =>
        text == null ? 0 : RegExp(r'\[\[id:').allMatches(text).length;
    final change = AgentChange(
      tool: tool,
      path: path,
      noteKey: noteKey ?? writer.editor?.store.historyKey(path) ?? path,
      nodeId: id,
      title: title,
      before: before,
      after: after,
      linksAdded: (links(after) - links(before)).clamp(0, 1 << 30),
      removed: removed,
    );
    changes.changes.add(change);
    await log.record(AgentLogEntry.of(changes, change, folder(), _now()));
  }
}

