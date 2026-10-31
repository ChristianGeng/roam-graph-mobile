import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart' show NoteWriter;
import '../edit/agent_changes.dart';
import '../graph/roam_db.dart' show TextHit;
import '../graph/roam_graph.dart';
import '../node_view/web_links.dart';
import 'ai_chat.dart';
import 'ai_models.dart';
import 'ai_settings.dart';
import 'ai_tools.dart' show NoteTextReader;
import 'chat_screen.dart';
import 'chat_store.dart';

/// The list of AI chats (#201): "Ask AI" opens it. Each row is a chat kept
/// on this device, with a spinner while it works and a dot when a new
/// answer has come since it was last opened. A chat opens on tap, "New
/// chat" starts one, and a swipe deletes a chat, with "Undo".
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({
    super.key,
    required this.graph,
    required this.readNote,
    this.startNode,
    this.openNewChat = false,
    this.aboutStartNode = false,
    this.openChatId,
    this.store,
    this.writer,
    this.openNode,
    this.post = postWithDartIo,
    this.agentLog = const FileAgentLog(),
    this.searchText,
    this.openUrl = openUrlOnDevice,
    this.getModels = getWithDartIo,
  });

  final ValueListenable<RoamGraph> graph;
  final NoteTextReader readNote;

  /// The node a new chat starts from.
  final RoamNode? startNode;

  /// Starts a new chat with [startNode] at once, as from a note's AI menu.
  final bool openNewChat;

  /// Puts the chats that started from [startNode] first, under "About this
  /// note", as from a note's AI menu (#215).
  final bool aboutStartNode;

  /// The store of the chats; by default the app's, from [ChatStoreScope].
  final ChatStore? store;

  /// The chat to open at once, after a tap on its notification (#202);
  /// empty or null opens the list only.
  final String? openChatId;

  final NoteWriter? writer;
  final OpenNode? openNode;
  final HttpPost post;
  final AgentLog agentLog;
  final Future<List<TextHit>> Function(String query, {int limit})? searchText;
  final UrlOpener openUrl;
  final HttpGet getModels;

  static Future<void> open(
    BuildContext context, {
    required ValueListenable<RoamGraph> graph,
    required NoteTextReader readNote,
    RoamNode? startNode,
    bool openNewChat = false,
    bool aboutStartNode = false,
    String? openChatId,
    NoteWriter? writer,
    OpenNode? openNode,
    Future<List<TextHit>> Function(String query, {int limit})? searchText,
    UrlOpener openUrl = openUrlOnDevice,
  }) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ChatListScreen(
        graph: graph,
        readNote: readNote,
        startNode: startNode,
        openNewChat: openNewChat,
        aboutStartNode: aboutStartNode,
        openChatId: openChatId,
        writer: writer,
        openNode: openNode,
        searchText: searchText,
        openUrl: openUrl,
      ),
    ),
  );

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late final ChatStore _store = widget.store ??
      ChatStoreScope.maybeOf(context) ??
      ChatStore(MemoryChatStorage());

  /// Waits for the saved chats to be read, to open a chat from a tap; and
  /// the chat it opens (the last one asked for).
  VoidCallback? _loadWait;
  String? _waitingFor;

  @override
  void initState() {
    super.initState();
    _store.openRequest.addListener(_openRequested);
    if (widget.openNewChat) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(null);
      });
    }
    if (widget.openChatId case final id? when id.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openById(id);
      });
    }
  }

  @override
  void dispose() {
    _store.openRequest.removeListener(_openRequested);
    if (_loadWait case final wait?) _store.removeListener(wait);
    super.dispose();
  }

  /// A tap on a notification while this list is the screen: opens the
  /// chat.
  void _openRequested() {
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    final id = _store.takeOpenRequest();
    if (id != null && id.isNotEmpty) _openById(id);
  }

  /// Opens the chat [id]; where the chats are still being read, when they
  /// are.
  void _openById(String id) {
    Chat? find() {
      for (final chat in _store.chats) {
        if (chat.id == id) return chat;
      }
      return null;
    }

    final chat = find();
    if (chat != null) {
      _open(chat);
    } else if (!_store.loaded) {
      // One listener, whatever the number of taps: the last tap wins.
      _waitingFor = id;
      if (_loadWait != null) return;
      void wait() {
        if (!_store.loaded) return;
        _store.removeListener(wait);
        _loadWait = null;
        final wanted = _waitingFor;
        _waitingFor = null;
        if (wanted == null || !mounted) return;
        for (final chat in _store.chats) {
          if (chat.id == wanted) {
            _open(chat);
            return;
          }
        }
      }

      _loadWait = wait;
      _store.addListener(wait);
    }
  }

  /// Opens [chat], or a new chat.
  Future<void> _open(Chat? chat) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        graph: widget.graph,
        readNote: widget.readNote,
        store: _store,
        chat: chat,
        startNode: chat == null ? widget.startNode : null,
        // The chat's "Chats" button goes back to this list (#215).
        listBelow: true,
        writer: widget.writer,
        openNode: widget.openNode,
        post: widget.post,
        agentLog: widget.agentLog,
        searchText: widget.searchText,
        openUrl: widget.openUrl,
        getModels: widget.getModels,
      ),
    ),
  );

  void _delete(Chat chat) {
    _store.remove(chat);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Chat deleted.'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _store.restore(chat),
          ),
        ),
      );
  }

  Future<void> _rename(Chat chat) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(chat.title),
    );
    if (title != null) _store.rename(chat, title);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask AI'),
        actions: [
          IconButton(
            tooltip: 'AI settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () =>
                AiSettingsScreen.open(context, graph: widget.graph.value),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('chat-new'),
        onPressed: () => _open(null),
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New chat'),
      ),
      body: ListenableBuilder(
        listenable: _store,
        // The rows follow their chats: a spinner, a dot, a new title.
        builder: (context, _) => ListenableBuilder(
          listenable: Listenable.merge(_store.chats),
          builder: (context, _) => _list(context),
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final chats = _store.chats;
    final theme = Theme.of(context);
    final noteId = widget.aboutStartNode ? widget.startNode?.id : null;
    final about = noteId == null
        ? const <Chat>[]
        : [for (final chat in chats) if (chat.startNodeId == noteId) chat];
    final others = about.isEmpty
        ? chats
        : [for (final chat in chats) if (chat.startNodeId != noteId) chat];
    return ListView(
      key: const ValueKey('chat-overview'),
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (_store.skipped > 0)
          Card(
            key: const ValueKey('chat-damaged'),
            child: ListTile(
              leading: const Icon(Icons.warning_amber),
              title: Text(
                _store.skipped == 1
                    ? 'One saved chat could not be read and was skipped.'
                    : '${_store.skipped} saved chats could not be read and '
                          'were skipped.',
              ),
            ),
          ),
        if (chats.isEmpty)
          Padding(
            key: const ValueKey('chat-none'),
            padding: const EdgeInsets.all(16),
            child: Text(
              'No chats yet. Tap "New chat" to ask about your notes. Chats '
              'are kept on this device only.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (about.isNotEmpty) ...[
          _heading(context, 'About this note', 'chat-about-note'),
          for (final chat in about) _row(context, chat),
          if (others.isNotEmpty)
            _heading(context, 'All chats', 'chat-all-chats'),
        ],
        for (final chat in others) _row(context, chat),
      ],
    );
  }

  Widget _heading(BuildContext context, String text, String key) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Chat chat) {
    final colors = Theme.of(context).colorScheme;
    final lines = [
      if (chat.startNodeTitle case final note? when note.isNotEmpty)
        'Note: $note',
      [
        if (chat.providerName.isNotEmpty) chat.providerName,
        if (chat.model.isNotEmpty) chat.model,
      ].join(' · '),
      if (chat.queued) 'Waiting' else _when(chat.lastUsed),
    ].where((line) => line.isNotEmpty).toList();
    return Dismissible(
      key: ValueKey('chat-row-${chat.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: colors.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
      ),
      onDismissed: (_) => _delete(chat),
      child: ListTile(
        key: ValueKey('chat-tile-${chat.id}'),
        leading: SizedBox(
          width: 24,
          child: Center(
            child: chat.queued
                ? Icon(Icons.hourglass_empty,
                    key: ValueKey('chat-wait-${chat.id}'), size: 20)
                : chat.sending
                ? SizedBox.square(
                    key: ValueKey('chat-spinner-${chat.id}'),
                    dimension: 20,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : chat.unseen
                ? Icon(Icons.circle,
                    key: ValueKey('chat-dot-${chat.id}'),
                    size: 12,
                    color: colors.primary,
                    semanticLabel: 'New answer')
                : null,
          ),
        ),
        title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(lines.join('\n')),
        isThreeLine: lines.length > 2,
        trailing: PopupMenuButton<String>(
          key: ValueKey('chat-menu-${chat.id}'),
          tooltip: 'Chat',
          onSelected: (choice) {
            if (choice == 'rename') {
              _rename(chat);
            } else {
              _delete(chat);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
        onTap: () => _open(chat),
      ),
    );
  }
}

/// `2026-10-29 14:05`, in local time.
String _when(DateTime time) {
  final t = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// The dialog of "Rename": it owns its field, so the field lives as long
/// as the dialog's route.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog(this.title);

  final String title;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _field = TextEditingController(text: widget.title);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename chat'),
    content: TextField(
      key: const ValueKey('chat-rename-field'),
      controller: _field,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Title'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const ValueKey('chat-rename-ok'),
        onPressed: () => Navigator.pop(context, _field.text),
        child: const Text('Rename'),
      ),
    ],
  );
}
