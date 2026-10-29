/// The AI chats, kept outside the chat screen (#201).
///
/// A [ChatStore] owns all chats and the requests they run. A chat keeps
/// working when its screen is closed, and the screen shows it again when
/// it is opened. Each chat is saved as one JSON file in the app's private
/// storage ([FileChatStorage]), never in the org folder.
///
/// What a chat file holds: the title, the times, the provider and model,
/// the ID of the start note and the transcript. It never holds an API key
/// (the store does not know any) nor the bytes of images the model saw.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../edit/agent_changes.dart';
import '../edit/change_set.dart';
import '../edit/edit_proposal.dart';
import '../platform/error_text.dart';
import '../platform/screen_awake.dart';
import 'agent_tools.dart';
import 'ai_chat.dart';
import 'ai_settings.dart';
import 'ai_visibility.dart';
import 'note_language.dart';

/// Above this many characters, the chat suggests a new chat: every message
/// sends the whole chat again.
const longChatCharacters = 100000;

/// The longest title a chat gets from its first message.
const _titleLength = 60;

/// One chat: its transcript, the session that runs it, and what the
/// screen shows about it.
class Chat extends ChangeNotifier {
  Chat(
    this.store, {
    required this.id,
    required this.createdAt,
    required this.lastUsed,
    this.providerId = '',
    this.providerName = '',
    this.model = '',
    this.startNodeId,
    this.startNodeTitle,
    this.customTitle,
    this.unseen = false,
  });

  final ChatStore store;

  /// The name of the chat's file, without `.json`.
  final String id;
  final DateTime createdAt;
  DateTime lastUsed;

  /// The preset ID and the name of the provider, and the model in use.
  String providerId;
  String providerName;
  String model;

  /// The note the chat was started from, if any.
  final String? startNodeId;
  final String? startNodeTitle;

  /// A title the user gave; null while the first message is the title.
  String? customTitle;

  /// A new answer has come since the chat was last opened.
  bool unseen;

  /// The transcript and the usage of a chat read from its file, until a
  /// session is made for it.
  List<ChatEntry> _stored = [];
  TokenUsage _storedUsage = TokenUsage.zero;

  /// The session that runs the chat; null until the chat screen made one.
  ChatSession? session;

  /// The agent's writes for this chat (#82); null when the AI may not
  /// change notes.
  AgentWriter? agent;

  /// The hidden tags the tools of this chat use.
  AiVisibility visibility = AiVisibility.none;

  /// The limit on notes per change set (#76).
  int maxFiles = 20;

  /// Whether the start note may be named to the AI: not when it is hidden
  /// from AI (#57).
  bool startShown = false;

  /// The language of new notes in this chat (#172).
  NoteLanguage? language;

  /// The edits the AI proposed (#39), by the ID of the tool call, and what
  /// became of those reviewed.
  final proposals = <String, EditProposal>{};
  final proposalStatus = <String, String>{};

  /// The change sets the AI proposed (#76), by the ID of the tool call;
  /// built when first reviewed, and kept, so their state stays.
  final setProposals = <String, ({List<EditProposal> edits, String summary})>{};
  final sets = <String, ChangeSet>{};

  /// What the agent changed, by the index of the message in the
  /// transcript that asked for it.
  final turnChanges = <int, AgentChanges>{};

  /// A request of this chat is running or waits for its turn.
  bool sending = false;

  /// The chat waits for a free place: the most chats working at the same
  /// time is reached.
  bool queued = false;

  /// My message while the chat waits; it is in the transcript once the
  /// request starts.
  String? pendingText;

  /// Why the last request failed, with more to copy (#180).
  String? error;
  ErrorReport? errorDetail;

  /// How many chat screens show this chat now.
  int viewers = 0;

  /// True while the chat is deleted (and may be brought back).
  bool discarded = false;

  List<ChatEntry> get transcript => session?.transcript ?? _stored;
  TokenUsage get usage => session?.usage ?? _storedUsage;

  /// The title: mine, or the first message cut to one line.
  String get title {
    final own = customTitle?.trim() ?? '';
    if (own.isNotEmpty) return own;
    for (final entry in transcript) {
      if (entry is UserMessage) {
        final line = entry.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (line.isEmpty) continue;
        return line.length > _titleLength
            ? '${line.substring(0, _titleLength)}…'
            : line;
      }
    }
    return 'New chat';
  }

  /// The rough size of the chat in characters: what every message sends
  /// again.
  int get characters {
    var n = 0;
    for (final entry in transcript) {
      switch (entry) {
        case UserMessage():
          n += entry.text.length + (entry.context?.length ?? 0);
        case AssistantMessage():
          n += entry.text.length;
          for (final call in entry.toolCalls) {
            n += jsonEncode(call.input).length;
          }
        case ToolResults():
          for (final result in entry.results) {
            n += result.content.length;
          }
      }
    }
    return n;
  }

  /// Gives the chat its [session]; a chat read from its file continues
  /// with the saved transcript.
  void attach(ChatSession session) {
    session.transcript.addAll(_stored);
    session.usage = _storedUsage;
    _stored = [];
    _storedUsage = TokenUsage.zero;
    this.session = session;
  }

  /// Stops the chat's session and keeps its transcript, so a session can
  /// be made again.
  void detach() {
    final old = session;
    if (old == null) return;
    _stored = [...old.transcript];
    _storedUsage = old.usage;
    old.cancel();
    session = null;
    agent = null;
  }

  /// Tells the listeners that something changed and saves the chat.
  void changed() {
    notifyListeners();
    store.save(this);
  }

  void _rename(String title) {
    final own = title.trim();
    customTitle = own.isEmpty ? null : own;
    store.save(this);
    notifyListeners();
  }

  void _setQueued(bool value) {
    queued = value;
    notifyListeners();
  }

  /// The chat is open on a screen: the answers are seen.
  void markSeen() {
    if (!unseen) return;
    unseen = false;
    store.save(this);
    notifyListeners();
  }

  /// Sends [text] as my message and runs the turn.
  Future<void> send(String text, {String? context}) async {
    final s = session;
    if (s == null || sending) return;
    pendingText = text;
    // The agent's changes for this message are kept under its index.
    if (agent case final agent?) {
      turnChanges[s.transcript.length] = agent.startMessage(prompt: text);
    }
    await run(() => s.send(text, context: context, onUpdate: _step));
  }

  /// Sends the conversation again after an error.
  Future<void> resume() async {
    final s = session;
    if (s == null || sending) return;
    await run(() => s.resume(onUpdate: _step));
  }

  void _step() {
    if (!discarded) lastUsed = store.now();
    changed();
  }

  /// Runs [work] as a request of this chat: it waits for a free place
  /// (the most chats working at the same time is a setting), holds the
  /// screen on, and ends with the error it threw, if any, in [error].
  Future<void> run(Future<void> Function() work) async {
    if (sending) return;
    sending = true;
    error = null;
    errorDetail = null;
    store._adopt(this);
    final before = transcript.length;
    notifyListeners();
    final got = await store._acquire(this);
    if (!got) {
      // Deleted while it waited.
      sending = false;
      pendingText = null;
      notifyListeners();
      return;
    }
    pendingText = null;
    try {
      await whileScreenOn(work);
    } on AiError catch (e) {
      error = e.message;
      errorDetail = e.report();
    } finally {
      store._release();
      sending = false;
      pendingText = null;
      if (!discarded) {
        lastUsed = store.now();
        if (viewers == 0 && error == null && transcript.length > before) {
          unseen = true;
        }
        store.save(this);
      }
      notifyListeners();
    }
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'title': customTitle,
        'created': createdAt.toUtc().toIso8601String(),
        'lastUsed': lastUsed.toUtc().toIso8601String(),
        'provider': providerId,
        'providerName': providerName,
        'model': session?.config.model ?? model,
        'startNode': startNodeId,
        'startNodeTitle': startNodeTitle,
        'unseen': unseen,
        'usage': {
          'input': usage.input,
          'cached': usage.cached,
          'output': usage.output,
        },
        'transcript': [for (final entry in transcript) _entryJson(entry)],
      };

  /// The chat of a file's [json]; throws [FormatException] where the file
  /// is not a chat.
  factory Chat.fromJson(ChatStore store, String id, Object? json) {
    final m = _map(json);
    final chat = Chat(
      store,
      id: id,
      createdAt: _time(m['created']),
      lastUsed: _time(m['lastUsed']),
      providerId: _text(m['provider']) ?? '',
      providerName: _text(m['providerName']) ?? '',
      model: _text(m['model']) ?? '',
      startNodeId: _text(m['startNode']),
      startNodeTitle: _text(m['startNodeTitle']),
      customTitle: _text(m['title']),
      unseen: m['unseen'] == true,
    );
    final usage = m['usage'];
    if (usage is Map) {
      int n(String key) => usage[key] is int ? usage[key] as int : 0;
      chat._storedUsage = TokenUsage(
          input: n('input'), cached: n('cached'), output: n('output'));
    }
    final entries = m['transcript'];
    if (entries is! List) throw const FormatException('no transcript');
    chat._stored = [for (final entry in entries) _entryFrom(entry)];
    return chat;
  }
}

Map<String, Object?> _map(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  throw const FormatException('not an object');
}

List<Object?> _list(Object? value) {
  if (value is List) return value.cast<Object?>();
  throw const FormatException('not a list');
}

String? _text(Object? value) => value is String ? value : null;

String _need(Map<String, Object?> m, String key) {
  final value = m[key];
  if (value is String) return value;
  throw FormatException('"$key" is not text');
}

DateTime _time(Object? value) {
  if (value is String) return DateTime.parse(value);
  throw const FormatException('not a time');
}

Map<String, Object?> _callJson(ToolCall call) => {
      'id': call.id,
      'name': call.name,
      'input': call.input,
      if (call.badArguments != null) 'bad': call.badArguments,
    };

ToolCall _callFrom(Object? json) {
  final m = _map(json);
  return ToolCall(_need(m, 'id'), _need(m, 'name'), _map(m['input']),
      badArguments: _text(m['bad']));
}

/// A tool result for the file: an image is not kept, only a line that
/// says there was one.
Map<String, Object?> _resultJson(ToolResult result) => {
      'call': _callJson(result.call),
      'content': result.image == null
          ? result.content
          : '${result.content}\n[image: ${result.image!.mediaType}, '
              'not kept in the chat]',
    };

ToolResult _resultFrom(Object? json) {
  final m = _map(json);
  return ToolResult(_callFrom(m['call']), _need(m, 'content'));
}

Map<String, Object?> _entryJson(ChatEntry entry) => switch (entry) {
      UserMessage() => {
          'type': 'user',
          'text': entry.text,
          if (entry.context != null) 'context': entry.context,
        },
      AssistantMessage() => {
          'type': 'assistant',
          'text': entry.text,
          'model': entry.model,
          'toolCalls': [for (final call in entry.toolCalls) _callJson(call)],
          'searches': [for (final r in entry.searches) _resultJson(r)],
          'paused': entry.paused,
          if (entry.raw != null) 'raw': entry.raw,
        },
      ToolResults() => {
          'type': 'results',
          'results': [for (final r in entry.results) _resultJson(r)],
        },
    };

ChatEntry _entryFrom(Object? json) {
  final m = _map(json);
  switch (m['type']) {
    case 'user':
      return UserMessage(_need(m, 'text'), context: _text(m['context']));
    case 'assistant':
      return AssistantMessage(
        text: _need(m, 'text'),
        model: _need(m, 'model'),
        toolCalls: [for (final c in _list(m['toolCalls'])) _callFrom(c)],
        searches: [for (final r in _list(m['searches'])) _resultFrom(r)],
        paused: m['paused'] == true,
        raw: m['raw'],
      );
    case 'results':
      return ToolResults([for (final r in _list(m['results'])) _resultFrom(r)]);
  }
  throw const FormatException('unknown entry');
}

/// A saved chat as the storage holds it: [text] is null where the file
/// could not be read.
class StoredChat {
  const StoredChat(this.id, this.text);

  final String id;
  final String? text;
}

/// Where chats are kept; tests replace it.
abstract interface class ChatStorage {
  Future<List<StoredChat>> readAll();
  Future<void> write(String id, String text);
  Future<void> delete(String id);
}

/// [ChatStorage] in memory.
class MemoryChatStorage implements ChatStorage {
  /// The files by chat ID.
  final files = <String, String>{};

  @override
  Future<List<StoredChat>> readAll() async => [
        for (final MapEntry(:key, :value) in files.entries)
          StoredChat(key, value),
      ];

  @override
  Future<void> write(String id, String text) async => files[id] = text;

  @override
  Future<void> delete(String id) async => files.remove(id);
}

/// [ChatStorage] with one JSON file per chat in the folder `chats` of the
/// app's private support folder, next to the database (#201). Where the
/// folder is not available, nothing is read and nothing is written.
class FileChatStorage implements ChatStorage {
  const FileChatStorage({this.directory});

  /// Where the files are; by default in the app's support folder.
  final String? directory;

  Future<Directory?> _folder({bool create = false}) async {
    try {
      final path =
          directory ?? '${(await getApplicationSupportDirectory()).path}/chats';
      final folder = Directory(path);
      if (create && !folder.existsSync()) folder.createSync(recursive: true);
      return folder;
    } on Exception {
      return null;
    }
  }

  @override
  Future<List<StoredChat>> readAll() async {
    final folder = await _folder();
    if (folder == null || !folder.existsSync()) return const [];
    final found = <StoredChat>[];
    try {
      for (final entity in folder.listSync()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final name = entity.uri.pathSegments.last;
        String? text;
        try {
          text = entity.readAsStringSync();
        } on Exception {
          text = null;
        }
        found.add(StoredChat(name.substring(0, name.length - 5), text));
      }
    } on FileSystemException {
      // A folder that cannot be listed holds no chats for the app.
    }
    return found;
  }

  @override
  Future<void> write(String id, String text) async {
    final folder = await _folder(create: true);
    if (folder == null) return;
    final file = File('${folder.path}/$id.json');
    // Written next to the file and renamed, so a crash cannot leave half a
    // chat.
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(text, flush: true);
    temporary.renameSync(file.path);
  }

  @override
  Future<void> delete(String id) async {
    final folder = await _folder();
    if (folder == null) return;
    final file = File('${folder.path}/$id.json');
    if (file.existsSync()) file.deleteSync();
  }
}

/// All chats, and the rule for how many may work at the same time.
class ChatStore extends ChangeNotifier {
  ChatStore(this.storage, {int maxParallel = 3, DateTime Function()? now})
      : _maxParallel = max(1, maxParallel),
        now = now ?? DateTime.now;

  final ChatStorage storage;

  /// The clock; tests replace it.
  final DateTime Function() now;

  final _chats = <Chat>[];

  /// How many files could not be read at the last [load]. They are left
  /// where they are.
  int skipped = 0;

  /// True once the saved chats are read.
  bool loaded = false;

  int _maxParallel;
  int _running = 0;
  final _waiting = <({Chat chat, Completer<bool> done})>[];
  Future<void> _writes = Future.value();
  final _random = Random();

  /// The chats with at least one message, the last used first.
  List<Chat> get chats =>
      [..._chats]..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));

  /// The most chats that may send at the same time (at least 1).
  int get maxParallel => _maxParallel;
  set maxParallel(int value) {
    _maxParallel = max(1, value);
    _pump();
  }

  /// A new chat, not yet in the list: it joins the list with its first
  /// message.
  Chat create({
    String providerId = '',
    String providerName = '',
    String model = '',
    String? startNodeId,
    String? startNodeTitle,
  }) {
    final time = now();
    return Chat(
      this,
      id: 'c${time.microsecondsSinceEpoch.toRadixString(36)}'
          '${_random.nextInt(1 << 20).toRadixString(36)}',
      createdAt: time,
      lastUsed: time,
      providerId: providerId,
      providerName: providerName,
      model: model,
      startNodeId: startNodeId,
      startNodeTitle: startNodeTitle,
    );
  }

  /// Reads the saved chats. A file that cannot be read is skipped and
  /// counted in [skipped]; a chat not used for [keepDays] days is deleted
  /// (0 keeps all).
  Future<void> load({int keepDays = 0}) async {
    final cutoff =
        keepDays > 0 ? now().subtract(Duration(days: keepDays)) : null;
    var bad = 0;
    final found = await storage.readAll();
    for (final item in found) {
      Chat? chat;
      final text = item.text;
      if (text != null) {
        try {
          chat = Chat.fromJson(this, item.id, jsonDecode(text));
        } on FormatException {
          chat = null;
        } on TypeError {
          chat = null;
        }
      }
      if (chat == null) {
        bad++;
        continue;
      }
      if (cutoff != null && chat.lastUsed.isBefore(cutoff)) {
        _writes = _writes.then((_) => _delete(item.id));
        continue;
      }
      // A chat started before the files were read stays.
      if (_chats.any((c) => c.id == item.id)) continue;
      _chats.add(chat);
    }
    skipped = bad;
    loaded = true;
    notifyListeners();
  }

  /// Completes when the files written so far are written.
  Future<void> flush() => _writes;

  /// Saves [chat] in the background; a chat that is not in the list is not
  /// saved.
  void save(Chat chat) {
    if (!_chats.contains(chat)) return;
    final text = jsonEncode(chat.toJson());
    _writes = _writes.then((_) => _write(chat.id, text));
  }

  Future<void> _write(String id, String text) async {
    try {
      await storage.write(id, text);
    } on Exception {
      // The chat stays in memory and is written with the next change.
    }
  }

  Future<void> _delete(String id) async {
    try {
      await storage.delete(id);
    } on Exception {
      // A file that stays is read again at the next start.
    }
  }

  void _adopt(Chat chat) {
    if (_chats.contains(chat)) return;
    _chats.add(chat);
    notifyListeners();
  }

  /// Deletes [chat] and its file; its request stops. [restore] brings it
  /// back.
  void remove(Chat chat) {
    if (!_chats.remove(chat)) return;
    chat.discarded = true;
    chat.detach();
    _cancelWait(chat);
    _writes = _writes.then((_) => _delete(chat.id));
    notifyListeners();
  }

  /// Brings back a chat that [remove] deleted ("Undo").
  void restore(Chat chat) {
    chat.discarded = false;
    if (!_chats.contains(chat)) _chats.add(chat);
    save(chat);
    notifyListeners();
  }

  /// Gives [chat] the title [title]; an empty one brings back the first
  /// message as the title.
  void rename(Chat chat, String title) {
    chat._rename(title);
    notifyListeners();
  }

  /// A place to work in, for [chat]: at once, or when another chat ends.
  /// False when the chat was deleted while it waited.
  Future<bool> _acquire(Chat chat) {
    if (_running < _maxParallel && _waiting.isEmpty) {
      _running++;
      return Future.value(true);
    }
    final done = Completer<bool>();
    _waiting.add((chat: chat, done: done));
    chat._setQueued(true);
    return done.future;
  }

  void _release() {
    _running--;
    _pump();
  }

  void _pump() {
    while (_running < _maxParallel && _waiting.isNotEmpty) {
      final next = _waiting.removeAt(0);
      _running++;
      next.chat._setQueued(false);
      next.done.complete(true);
    }
  }

  void _cancelWait(Chat chat) {
    final index = _waiting.indexWhere((w) => w.chat == chat);
    if (index < 0) return;
    final waiter = _waiting.removeAt(index);
    waiter.chat._setQueued(false);
    waiter.done.complete(false);
  }
}

/// The chat store for the screens below it.
class ChatStoreScope extends InheritedNotifier<ChatStore> {
  const ChatStoreScope({
    super.key,
    required ChatStore store,
    required super.child,
  }) : super(notifier: store);

  /// The store, or null where there is no scope, as in tests of a single
  /// screen.
  static ChatStore? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatStoreScope>()?.notifier;
}

/// Makes the [ChatStore] for the whole app, above the navigator like the
/// AI settings, reads the saved chats at the start and follows "Most chats
/// working at the same time".
class ChatStoreHost extends StatefulWidget {
  const ChatStoreHost({
    super.key,
    this.storage = const FileChatStorage(),
    required this.child,
  });

  final ChatStorage storage;
  final Widget child;

  @override
  State<ChatStoreHost> createState() => _ChatStoreHostState();
}

class _ChatStoreHostState extends State<ChatStoreHost> {
  late final ChatStore _store = ChatStore(widget.storage);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final settings = await AiSettingsScope.current(context);
    _store.maxParallel = settings.maxParallelChats;
    await _store.load(keepDays: settings.keepChatsDays);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store.maxParallel = AiSettingsScope.of(context).maxParallelChats;
  }

  @override
  Widget build(BuildContext context) =>
      ChatStoreScope(store: _store, child: widget.child);
}
