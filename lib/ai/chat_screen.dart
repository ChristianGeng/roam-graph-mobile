import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../edit/agent_changes.dart';
import '../edit/change_set.dart';
import '../edit/change_set_screen.dart';
import '../edit/diff_screen.dart';
import '../edit/edit_proposal.dart';
import '../edit/note_editor.dart';
import '../edit/recent_changes_screen.dart';
import '../edit/save_messages.dart';
import '../graph/roam_db.dart' show TextHit;
import '../graph/roam_graph.dart';
import '../node_view/web_links.dart';
import '../platform/error_text.dart';
import '../platform/screen_awake.dart';
import '../settings/view_settings.dart';
import 'agent_tools.dart';
import 'ai_chat.dart';
import 'ai_images.dart';
import 'ai_models.dart';
import 'ai_providers.dart';
import 'ai_settings.dart';
import 'ai_tools.dart';
import 'chart.dart' show defaultChartColors;
import 'chat_note.dart';
import 'chat_store.dart';
import 'edit_tools.dart';
import 'model_picker.dart';
import 'note_from_answer.dart';
import 'note_language.dart';
import 'web_access.dart';

/// Opens a node by its ID, from a link in an answer.
typedef OpenNode = void Function(BuildContext context, String id);

/// One AI chat (#60): I ask, the model reads the graph with the tools of
/// my org-roam MCP server (#58) through the provider of the AI settings
/// (#59), and answers. Its tool calls are shown, `id:` links in answers
/// open the node, and an answer can become a new node through the capture
/// screen, so I review it before anything is written.
///
/// The chat itself lives in the [ChatStore] (#201): closing this screen
/// does not stop a request, and the chat is shown again from the chat
/// list. Without a [chat], the screen starts a new one.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.graph,
    required this.readNote,
    this.chat,
    this.store,
    this.startNode,
    this.writer,
    this.openNode,
    this.post = postWithDartIo,
    this.agentLog = const FileAgentLog(),
    this.searchText,
    this.openUrl = openUrlOnDevice,
    this.getModels = getWithDartIo,
  });

  /// HTTP for the provider's model list, to tell when the chosen model is
  /// gone (#113); tests replace it.
  final HttpGet getModels;

  /// Opens web, mail and phone links in answers in another app (#108).
  final UrlOpener openUrl;

  /// The app's full-text index, for the AI's text search (#98).
  final Future<List<TextHit>> Function(String query, {int limit})? searchText;

  final ValueListenable<RoamGraph> graph;
  final NoteTextReader readNote;

  /// The chat to show; null starts a new one.
  final Chat? chat;

  /// The store of [chat]; by default that of the app, or, where there is
  /// none (tests of this screen alone), one of its own.
  final ChatStore? store;

  /// The node a new chat is started from; the first message names it.
  final RoamNode? startNode;

  /// Writes new nodes; without it, there is no "Save as new node".
  final NoteWriter? writer;

  /// Opens a node from a link in an answer.
  final OpenNode? openNode;

  /// HTTP; tests replace it.
  final HttpPost post;

  /// Where the agent's changes are logged (#82).
  final AgentLog agentLog;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final ChatStore _store;
  late Chat _chat;
  ProviderConfig? _config;
  String _defaultModel = '';
  String _strongModel = '';
  String? _setupProblem;

  /// Set when the chosen model is not in the provider's list now (#113).
  String? _modelGone;

  /// The hidden tags the tools were made with.
  Set<String>? _hiddenTags;

  /// Undo is running for this message.
  int? _undoing;

  /// The index of the answer whose note the AI is writing for "Save as new
  /// node" in review and off mode (#145).
  int? _preparing;

  // What belongs to the chat, and so outlives this screen.
  ChatSession? get _session => _chat.session;
  bool get _sending => _chat.sending;
  String? get _error => _chat.error;
  ErrorReport? get _errorDetail => _chat.errorDetail;
  AgentWriter? get _agent => _chat.agent;
  bool get _startShown => _chat.startShown;
  NoteLanguage? get _language => _chat.language;
  Map<String, EditProposal> get _proposals => _chat.proposals;
  Map<String, String> get _proposalStatus => _chat.proposalStatus;
  Map<String, ({List<EditProposal> edits, String summary})> get _setProposals =>
      _chat.setProposals;
  Map<String, ChangeSet> get _sets => _chat.sets;
  Map<int, AgentChanges> get _turnChanges => _chat.turnChanges;

  String? get _languageName =>
      _language == null ? null : languageName(_language!.code);

  /// The node the chat was started from, if the graph has it.
  RoamNode? get _startNode {
    final id = _chat.startNodeId;
    return id == null ? null : widget.graph.value.nodes[id];
  }

  @override
  void initState() {
    super.initState();
    _store = widget.store ??
        ChatStoreScope.maybeOf(context) ??
        ChatStore(MemoryChatStorage());
    _chat = widget.chat ?? _newChatOf(_store);
    _show(_chat);
    widget.graph.addListener(_refreshTools);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Chat _newChatOf(ChatStore store) => store.create(
        startNodeId: widget.startNode?.id,
        startNodeTitle: widget.startNode?.displayTitle,
      );

  /// This screen shows [chat] now: its answers count as seen.
  void _show(Chat chat) {
    chat.viewers++;
    chat.addListener(_onChat);
    // After the build: other screens listen to the chat too, and must not
    // be changed while a frame is built.
    WidgetsBinding.instance.addPostFrameCallback((_) => chat.markSeen());
  }

  void _leave(Chat chat) {
    chat.removeListener(_onChat);
    chat.viewers--;
  }

  /// The chat changed, for example a request made a step.
  void _onChat() {
    if (!mounted) return;
    setState(() {});
    _toEnd();
  }

  @override
  void didUpdateWidget(ChatScreen old) {
    super.didUpdateWidget(old);
    if (old.graph != widget.graph) {
      old.graph.removeListener(_refreshTools);
      widget.graph.addListener(_refreshTools);
      _refreshTools();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // New hidden tags apply to the next tool call of an open chat.
    final tags = AiSettingsScope.of(context).hiddenTags.toSet();
    if (_hiddenTags != null && !setEquals(tags, _hiddenTags)) {
      _refreshTools();
    }
  }

  @override
  void dispose() {
    widget.graph.removeListener(_refreshTools);
    // A request under way goes on: the chat belongs to the store (#201).
    _leave(_chat);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  RoamTools _tools(AiSettings settings) => RoamTools(
    widget.graph.value,
    readNote: widget.readNote,
    visibility: settings.visibility,
    searchText: widget.searchText,
  );

  /// The tools on the graph and the hidden tags as they are now: after a
  /// scan brought new notes, or a tag was hidden.
  void _refreshTools() {
    final session = _session;
    if (session == null || !mounted) return;
    final settings = AiSettingsScope.of(context);
    _hiddenTags = settings.hiddenTags.toSet();
    _chat.visibility = settings.visibility;
    session.tools = _tools(settings);
  }

  /// Makes the session of the chat with the settings as they are now: for
  /// a new chat, or one read from its file. A chat that has a session
  /// keeps it; [fresh] makes the session again, after a change in AI
  /// settings.
  Future<void> _start({bool fresh = false}) async {
    if (!mounted) return;
    final chat = _chat;
    final settings = await AiSettingsScope.current(context);
    if (!mounted || !identical(chat, _chat)) return;
    // A chat with messages keeps its provider; a chat without any takes
    // the provider of the settings as they are now.
    final providerId = chat.providerId.isNotEmpty &&
            (!fresh || chat.transcript.isNotEmpty)
        ? chat.providerId
        : null;
    final values = settings.providerSettings(providerId);
    final kept = chat.session;
    if (kept != null && !fresh) {
      kept.tools = _tools(settings);
      chat.visibility = settings.visibility;
      setState(() {
        _config = kept.config;
        _hiddenTags = settings.hiddenTags.toSet();
        _defaultModel = values.defaultModel;
        _strongModel = values.strongModel;
        _setupProblem = null;
        _modelGone = null;
      });
      if (!chat.sending) unawaited(_checkModel(kept.config, kept.config.model));
      return;
    }
    final keys = AiSettingsScope.keysOf(context);
    final made = keys == null
        ? null
        : await providerConfig(settings, keys, id: providerId);
    if (!mounted || !identical(chat, _chat)) return;
    // A chat with messages continues with its saved model. The model of
    // the settings as they are now is used for a chat without messages, and
    // where the saved model is gone.
    final config = made != null &&
            chat.model.isNotEmpty &&
            !(fresh && (chat.transcript.isEmpty || _modelGone != null))
        ? made.withModel(chat.model)
        : made;
    // Only the agent makes images: other modes do not wait for it.
    final maker = widget.writer?.editor != null &&
            settings.editMode == AiEditMode.agent
        ? await _imageMaker(settings, keys)
        : null;
    if (!mounted || !identical(chat, _chat)) return;
    // Charts need no image model, only the image folder (#184).
    String? chartFolder;
    if (widget.writer?.editor != null &&
        settings.editMode == AiEditMode.agent &&
        widget.writer?.createFile != null) {
      chartFolder = maker?.folder ??
          (await ViewSettingsScope.current(context,
                  limit: const Duration(seconds: 10)))
              .imageFolder;
      if (!mounted || !identical(chat, _chat)) return;
    }
    // The chart is always on white: the colours of a light scheme with the
    // theme's seed, also in the dark theme.
    final scheme = ColorScheme.fromSeed(
        seedColor: Theme.of(context).colorScheme.primary,
        brightness: Brightness.light);
    final start = _startNode;
    var startShown = start != null && !settings.visibility.hides(start);
    if (startShown) {
      final file = await widget.readNote(start.file);
      startShown =
          file == null || !settings.visibility.hidesInText(start, file);
    }
    if (!mounted || !identical(chat, _chat)) return;
    final language = await decideLanguage(
      settings.visibility.visibleGraph(widget.graph.value),
      startShown ? start : null,
      read: widget.readNote,
      fallback: settings.newNoteLanguage,
    );
    if (!mounted || !identical(chat, _chat)) return;
    // The session of a chat without messages is made again; tool-call IDs
    // can repeat across chats, so nothing of an old one may stay.
    final empty = chat.transcript.isEmpty;
    chat.detach();
    final editor = widget.writer?.editor;
    // What the AI may change, as AI settings say, and only where notes
    // can be saved.
    final mode = editor == null ? AiEditMode.off : settings.editMode;
    final agent = mode == AiEditMode.agent
        ? AgentWriter(
            writer: widget.writer!,
            visibleGraph: () =>
                settings.visibility.visibleGraph(widget.graph.value),
            hiddenIds: () => settings.visibility.hiddenIds(widget.graph.value),
            visibility: settings.visibility,
            folder: () => editor!.store.historyKey('').split('\n').first,
            limit: settings.maxAgentChanges,
            log: widget.agentLog,
            images: maker,
            chartFolder: chartFolder,
            chartLimit: settings.maxImagesPerMessage,
            chartColors: [
              scheme.primary,
              scheme.tertiary,
              scheme.secondary,
              ...defaultChartColors,
            ],
            language: language.code,
          )
        : null;
    final readNote = widget.readNote;
    setState(() {
      if (empty) {
        chat.proposals.clear();
        chat.proposalStatus.clear();
        chat.setProposals.clear();
        chat.sets.clear();
        chat.turnChanges.clear();
      }
      chat.language = language;
      chat.startShown = startShown;
      chat.visibility = settings.visibility;
      chat.maxFiles = settings.maxChangeSetFiles;
      chat.agent = agent;
      _hiddenTags = settings.hiddenTags.toSet();
      _config = config;
      _defaultModel = values.defaultModel;
      _strongModel = values.strongModel;
      _setupProblem = config == null
          ? 'The AI settings are not available.'
          : config.model.isEmpty
          ? 'Choose a model for ${config.name} in AI settings.'
          : config.keyRequired && config.apiKey.isEmpty
          ? 'Enter the API key for ${config.name} in AI settings.'
          : null;
      _modelGone = null;
      if (config != null) {
        chat.providerId = providerId ?? settings.provider;
        chat.providerName = config.name;
        chat.model = config.model;
        chat.attach(ChatSession(
          tools: _tools(settings),
          config: config,
          post: widget.post,
          maxToolRounds: settings.maxToolRounds,
          toolList: switch (mode) {
            AiEditMode.off => null,
            AiEditMode.review => [
                ...aiTools,
                proposeEditTool,
                proposeEditsTool(settings.maxChangeSetFiles),
              ],
            AiEditMode.agent => [...aiTools, ...agent!.tools],
          },
          system: withToday(
              '${mode == AiEditMode.agent ? agentSystemPrompt : systemPrompt} '
              '${languagePrompt(language)}',
              DateTime.now()),
          toolImage: agent?.imageFor,
          web: settings.webAccess
              ? WebAccess(
                  limit: settings.maxWebSearches,
                  search: hasWebSearch(config),
                )
              : null,
          handlers: {
            if (mode == AiEditMode.review) ...{
              'propose_edit': (call) => _proposeEdit(chat, readNote, call),
              'propose_edits': (call) => _proposeEditSet(chat, readNote, call),
            },
            ...?agent?.handlers,
          },
        ));
      }
    });
    if (_setupProblem == null && config != null) {
      unawaited(_checkModel(config, config.model));
    }
  }

  /// Makes the session again after a change of AI settings, where the
  /// chat has no messages yet.
  void _restart() {
    if (mounted && _chat.transcript.isEmpty && !_chat.sending) {
      _start(fresh: true);
    }
  }

  /// The image models of "Images with:" and "Infographics with:" for the
  /// agent's `create_image` (#129, #183), or null where neither is set
  /// up: then the tool is not offered.
  Future<ImageMaker?> _imageMaker(
      AiSettings settings, ApiKeyStore? keys) async {
    if (keys == null || widget.writer?.createFile == null) return null;
    final preset = imagePreset(settings);
    final agents = AiSettingsScope.imageAgentsOf(context, preset.id);
    final config = await imageConfig(settings, keys);
    if (!mounted) return null;
    final noIllustrations = _cannotDraw(preset, config);
    // "Infographics with:" (#183), where it is not "Images with:"; the
    // tool is offered when either of the two can draw.
    ImageModel? infographics;
    if (settings.infographicProvider.isNotEmpty) {
      final preset = imagePreset(settings, ImageKind.infographic);
      final agents = AiSettingsScope.imageAgentsOf(context, preset.id);
      final config =
          await imageConfig(settings, keys, kind: ImageKind.infographic);
      if (!mounted) return null;
      if (config != null && _cannotDraw(preset, config) == null) {
        infographics = ImageModel(
          make: (prompt) =>
              makeImage(config, prompt, post: widget.post, agents: agents),
          name: '${config.provider.model} at ${preset.name}, '
              '${imageRegion(preset, config)}',
          maxPrompt: maxImagePrompt(config.api),
        );
      }
    }
    if (noIllustrations != null && infographics == null) return null;
    final view = await ViewSettingsScope.current(context,
        limit: const Duration(seconds: 10));
    return ImageMaker(
      make: (prompt) => config == null
          ? Future.error(AiError(noIllustrations!))
          : makeImage(config, prompt, post: widget.post, agents: agents),
      model: config == null || noIllustrations != null
          ? 'none'
          : '${config.provider.model} at ${preset.name}, '
              '${imageRegion(preset, config)}',
      folder: view.imageFolder,
      maxPrompt: config == null ? 4000 : maxImagePrompt(config.api),
      limit: settings.maxImagesPerMessage,
      infographics: infographics,
      noIllustrations: noIllustrations,
    );
  }

  /// Why [preset] cannot draw with [config]; null when it can.
  String? _cannotDraw(ProviderPreset preset, ImageConfig? config) {
    if (config == null) return '${preset.name} makes no images in the app';
    final provider = config.provider;
    if (provider.model.trim().isEmpty) {
      return 'no image model is chosen for ${preset.name}';
    }
    if (provider.keyRequired && provider.apiKey.isEmpty) {
      return 'the API key for ${preset.name} is missing';
    }
    return null;
  }

  /// Checks the chat's model against the provider's list as it is now,
  /// without holding up the chat; a model that is gone is named, with the
  /// way to AI settings (#113).
  ///
  /// The chat stays usable: a list may lack a model that still works, such
  /// as an alias, so the provider has the last word.
  Future<void> _checkModel(ProviderConfig config, String model) async {
    final listed = await listedModels(
      provider: config.name,
      api: config.api,
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      get: widget.getModels,
    );
    // Only for the chat and the model in use now.
    if (!mounted || _session?.config.model != model) return;
    final gone = modelGoneMessage(config.name, model, listed);
    setState(() => _modelGone = gone);
  }

  /// What the first message says about the node the chat came from.
  String? get _context {
    final node = _startNode;
    if (node == null || !_startShown) return null;
    return 'I am looking at the note "${node.displayTitle}" (ID ${node.id}). '
        'Read it with org_roam_read_node if you need it.';
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (_session == null || text.isEmpty || _sending) return;
    _input.clear();
    await _sendText(text);
  }

  /// Sends [text] as my message and runs the turn; also for "Save as new
  /// node" in agent mode (#145).
  Future<void> _sendText(String text) async {
    if (_session == null || _sending) return;
    await _chat.send(text, context: _context);
    _toEnd();
  }

  Future<void> _resume() async {
    if (_session == null || _sending || _preparing != null) return;
    await _chat.resume();
    _toEnd();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  });

  void _openLink(OrgLink link) {
    final location = link.location;
    if (externalLinkTarget(location) case final uri?) {
      // Web, mail and phone links open in their app (#108).
      openExternalLink(context, uri, widget.openUrl);
      return;
    }
    if (!location.startsWith('id:')) {
      _tell('The chat opens id:, web, mail and phone links, not '
          '"$location".');
      return;
    }
    final id = location.substring(3).split('::').first.trim();
    if (!widget.graph.value.nodes.containsKey(id)) {
      _tell('There is no node with the ID $id.');
      return;
    }
    widget.openNode?.call(context, id);
  }

  /// Opens the review of a change set (#76), built from the notes as they
  /// are now on first opening.
  Future<void> _reviewSet(String callId) async {
    final writer = widget.writer;
    final editor = writer?.editor;
    final proposed = _setProposals[callId];
    if (writer == null || editor == null || proposed == null) return;
    var set = _sets[callId];
    if (set == null) {
      final settings = AiSettingsScope.of(context);
      final graph = widget.graph.value;
      try {
        set = await ChangeSet.build(
          proposed.edits,
          editor: editor,
          visible: settings.visibility.visibleGraph(graph),
          graph: graph,
          maxFiles: _chat.maxFiles,
          summary: proposed.summary,
          visibility: settings.visibility,
        );
      } on ChangeSetError catch (e) {
        if (mounted) _tell(e.message, error: true);
        return;
      }
      _sets[callId] = set;
    }
    if (!mounted) return;
    await ChangeSetScreen.open(context, set, writer, widget.graph.value);
    if (mounted) setState(() {});
  }

  /// Shows the diff of a proposal against the note as it is now, and
  /// saves it only on "Save" (#38, #35).
  Future<void> _review(String callId) async {
    final proposal = _proposals[callId];
    final editor = widget.writer?.editor;
    if (proposal == null || editor == null) return;
    final graph = widget.graph.value;
    final node = graph.nodes[proposal.nodeId];
    if (node == null) {
      _tell('The note is no longer in the graph.', error: true);
      return;
    }
    final base = await editor.read(node.file);
    if (!mounted) return;
    if (base == null) {
      _tell('Could not read ${node.file}.', error: true);
      return;
    }
    if (AiSettingsScope.of(context).visibility.hidesInText(node, base.text)) {
      _tell('${node.file} is hidden from AI now; nothing was saved.', error: true);
      return;
    }
    final after = applyProposal(base.text, node, proposal);
    if (after == null) {
      _tell('The heading is no longer in ${node.file}.', error: true);
      return;
    }
    if (!sameLanguageLines(base.text, after)) {
      _tell('The AI\'s change would add or change a #+language: line, '
          'which stays as it is; nothing was saved.',
          error: true);
      return;
    }
    final unknown = unknownLinkIds(proposal.text, graph);
    final save = await DiffScreen.confirm(
      context,
      title: 'AI edit of ${node.displayTitle}',
      before: base.text,
      after: after,
      notes: [
        if (proposal.reason.isNotEmpty) 'The AI: ${proposal.reason}',
        if (unknown.isNotEmpty)
          'Links to IDs that are no note: ${unknown.join(', ')}.',
      ],
    );
    if (!save || !mounted) return;
    final result = await editor.save(node.file, base, after);
    if (!mounted) return;
    final message = saveMessage(result, node.file);
    setState(() {
      // Saved, also when indexing afterwards failed: not to save twice.
      if (result is Saved || result is SavedNotIndexed) {
        _proposalStatus[callId] = 'Saved.';
      }
    });
    _tell(message ?? 'Saved ${node.displayTitle}.',
        error: message != null && result is! SavedNotIndexed);
    if (message != null && result is NoWriteAccessToEdit) {
      await widget.writer?.allowWriting();
    }
  }

  /// The index of the last answer with text, which "your last answer"
  /// names.
  int _lastAnswer(List<ChatEntry> transcript) => transcript.lastIndexWhere(
      (e) => e is AssistantMessage && e.text.trim().isNotEmpty);

  /// The number of the answer at [index] among the answers with text,
  /// from 1.
  int _answerNumber(List<ChatEntry> transcript, int index) => transcript
      .take(index + 1)
      .where((e) => e is AssistantMessage && e.text.trim().isNotEmpty)
      .length;

  /// "Save as new node" under the answer at [index] (#145): the AI makes
  /// the note from it.
  ///
  /// In agent mode, a fixed message of mine asks the agent to make it with
  /// `create_node`, in the normal agent loop (summary, "Undo all", "Recent
  /// AI changes"). In review and off mode, one more request without tools
  /// asks for the title and body, which fill "New node" (#11); I review
  /// them. If that answer cannot be read, the title and text are proposed
  /// as for shared text (#15), as before.
  Future<void> _saveAsNode(NoteWriter writer, int index) async {
    final session = _session;
    if (session == null ||
        _sending ||
        _preparing != null ||
        _undoing != null ||
        session.waiting) {
      return;
    }
    final entry = session.transcript[index];
    if (entry is! AssistantMessage) return;
    final start = _startNode;
    if (_agent != null) {
      await _sendText(agentSaveRequest(
        answer: entry.text,
        isLast: index == _lastAnswer(session.transcript),
        number: _answerNumber(session.transcript, index),
        // A note hidden from AI is not named to it.
        start: start != null && _startShown
            ? (id: start.id, title: start.displayTitle)
            : null,
        language: _languageName,
      ));
      return;
    }
    setState(() => _preparing = index);
    ({String title, String body})? note;
    String? failed;
    ErrorReport? failedDetail;
    try {
      final reply = await whileScreenOn(() => session.askOnce(
            noteRequestEntries(session.transcript, index,
                startLinked: start != null, language: _languageName),
            system: noteFromAnswerSystem,
          ));
      note = parseNoteJson(reply);
    } on AiError catch (e) {
      failed = e.message;
      failedDetail = e.report();
    } finally {
      if (mounted) setState(() => _preparing = null);
    }
    // Closed, or a new chat, meanwhile.
    if (!mounted || !identical(session, _session)) return;
    if (note == null) {
      _tell(failed == null
          ? 'The AI\'s note could not be read, so the first line of the '
              'answer is the title.'
          : 'The AI could not write the note ($failed), so the first line '
              'of the answer is the title.',
          error: failed != null,
          // The copied text says what the snack bar says.
          report: failedDetail?.withMessage(
              'The AI could not write the note ($failed), so the first '
              'line of the answer is the title.'));
    }
    await _openCapture(writer, note ?? proposeNode(SharedText(entry.text)));
  }

  /// "New node", filled in with [proposal]; the node the chat came from
  /// is offered as a link.
  Future<void> _openCapture(
      NoteWriter writer, ({String title, String body}) proposal,
      {List<String> tags = const []}) async {
    final start = _startNode;
    final id = await CaptureScreen.open(
      context,
      writer,
      graph: widget.graph.value,
      initialTitle: proposal.title,
      initialBody: proposal.body,
      initialTags: tags,
      language: _language?.code ?? defaultNoteLanguage,
      linkTo: start == null ? null : (id: start.id, title: start.displayTitle),
    );
    if (id != null && mounted) widget.openNode?.call(context, id);
  }

  /// An [error] has a "Copy" action (#180); [report] says more.
  void _tell(String message, {bool error = false, ErrorReport? report}) {
    final messenger = ScaffoldMessenger.of(context);
    if (error) {
      showErrorSnackBar(messenger, message, report: report);
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// "Save chat as note" (#201): the whole chat as an Org note, with each
  /// question and answer as a heading; "New node" opens filled in, so I
  /// review it before it is saved.
  Future<void> _saveChatAsNote(NoteWriter writer) async {
    final chat = _chat;
    if (chat.transcript.isEmpty) return;
    final note = chatAsNote(
      title: chat.title,
      transcript: chat.transcript,
      provider: chat.providerName,
      model: _session?.config.model ?? chat.model,
      created: chat.createdAt,
    );
    await _openCapture(writer, note, tags: const [chatNoteTag]);
  }

  /// Uses [model] for the next messages of this chat. The AI settings are
  /// not changed, and the chat keeps its provider (#203).
  void _setModel(String model) {
    final session = _session;
    if (session == null || model.isEmpty) return;
    setState(() {
      session.model = model;
      _chat.model = model;
      _modelGone = null;
    });
    _chat.changed();
    // The switched-to model is checked too (#113).
    if (_config case final config?) {
      unawaited(_checkModel(config, model));
    }
  }

  /// "Model for this chat" (#203): the model picker of the chat's
  /// provider, with its badges, filters and prices. "EU only" applies as
  /// in the settings: the picker does not offer a model without an EU
  /// route.
  Future<void> _pickModel() async {
    final config = _session?.config;
    if (config == null || _sending) return;
    final picked = await ModelPickerScreen.open(
      context,
      provider: config.name,
      euOnly: config.euOnly,
      providerId: _chat.providerId,
      load: ({bool refresh = false}) => fetchModels(
        provider: config.name,
        api: config.api,
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        get: widget.getModels,
        refresh: refresh,
      ),
    );
    if (picked != null && mounted) _setModel(picked);
  }

  /// "Use the default model" (#203): back to the model of the AI
  /// settings.
  void _useDefaultModel() {
    if (_defaultModel.isNotEmpty && !_sending) _setModel(_defaultModel);
  }

  /// A new chat in this screen; the chat left stays in the chat list and
  /// goes on working.
  void _newChat() {
    if (_preparing != null || _undoing != null) return;
    if (_chat.transcript.isEmpty) {
      // Nothing to keep: the settings are read again.
      if (!_chat.sending) _start(fresh: true);
      return;
    }
    _leave(_chat);
    setState(() {
      _chat = _newChatOf(_store);
      _setupProblem = null;
      _modelGone = null;
      _config = null;
      _input.clear();
    });
    _show(_chat);
    _start();
  }


  @override
  Widget build(BuildContext context) {
    final session = _session;
    final config = _config;
    final model = session?.config.model ?? config?.model ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Ask AI'),
            if (config != null)
              Text(
                '${config.name} · $model',
                key: const ValueKey('chat-model'),
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          if (session != null &&
              _strongModel.isNotEmpty &&
              _strongModel != _defaultModel)
            PopupMenuButton<String>(
              tooltip: 'Model',
              icon: const Icon(Icons.tune),
              initialValue: model,
              onSelected: _setModel,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _defaultModel,
                  child: Text('Default: $_defaultModel'),
                ),
                PopupMenuItem(
                  value: _strongModel,
                  child: Text('Strong: $_strongModel'),
                ),
              ],
            ),
          if (widget.writer case final writer? when writer.editor != null)
            IconButton(
              tooltip: 'Recent AI changes',
              icon: const Icon(Icons.history),
              onPressed: () => RecentChangesScreen.open(context,
                  writer: writer, log: widget.agentLog),
            ),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _preparing != null ? null : _newChat,
          ),
          PopupMenuButton<String>(
            key: const ValueKey('chat-menu'),
            tooltip: 'Chat menu',
            onSelected: (value) {
              switch (value) {
                case 'pick-model':
                  _pickModel();
                case 'default-model':
                  _useDefaultModel();
                case 'save-note':
                  if (widget.writer case final writer?) {
                    _saveChatAsNote(writer);
                  }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'pick-model',
                enabled: session != null && !_sending,
                child: const Text('Model for this chat'),
              ),
              PopupMenuItem(
                value: 'default-model',
                enabled: session != null &&
                    !_sending &&
                    _defaultModel.isNotEmpty &&
                    model != _defaultModel,
                child: const Text('Use the default model'),
              ),
              if (widget.writer != null)
                PopupMenuItem(
                  value: 'save-note',
                  enabled: _chat.transcript.isNotEmpty,
                  child: const Text('Save chat as note'),
                ),
            ],
          ),
          IconButton(
            tooltip: 'AI settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await AiSettingsScreen.open(context,
                  graph: widget.graph.value);
              // The new settings apply to a new chat.
              _restart();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _list(context)),
          if (_chat.queued)
            Padding(
              key: const ValueKey('chat-waiting'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Waiting: ${_store.maxParallel} chats are working at the '
                'same time, the most AI settings allow. This one starts when '
                'one is done.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_sending) const LinearProgressIndicator(),
          _composer(context),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    final session = _session;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final children = <Widget>[];
    if (_modelGone case final gone? when _setupProblem == null) {
      children.add(
        Card(
          key: const ValueKey('chat-model-gone'),
          child: ListTile(
            title: Text(gone),
            trailing: TextButton(
              onPressed: () async {
                await AiSettingsScreen.open(context,
                    graph: widget.graph.value);
                if (mounted && !_chat.sending) _start(fresh: true);
              },
              child: const Text('AI settings'),
            ),
          ),
        ),
      );
    }
    if (_setupProblem case final problem?) {
      children.add(
        Card(
          key: const ValueKey('chat-setup'),
          child: ListTile(
            title: Text(problem),
            trailing: TextButton(
              onPressed: () async {
                await AiSettingsScreen.open(context,
                    graph: widget.graph.value);
                if (mounted && !_chat.sending) _start(fresh: true);
              },
              child: const Text('AI settings'),
            ),
          ),
        ),
      );
    } else if (session != null && session.transcript.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _startNode != null && !_startShown
                ? 'This note is hidden from AI by its tags, so the chat does '
                      'not name it. Ask about your other notes.'
                : _startNode == null
                ? 'Ask about your notes. The AI reads them with the tools of '
                      'your org-roam MCP server; notes hidden from AI stay '
                      'hidden.'
                : 'Ask about "${_startNode!.displayTitle}" and its '
                      'neighbours. The AI reads the notes with the tools of '
                      'your org-roam MCP server; notes hidden from AI stay '
                      'hidden.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    final transcript = _chat.transcript;
    var turn = 0;
    for (final (i, entry) in transcript.indexed) {
      if (entry is UserMessage) turn = i;
      // The agent's summary goes after the last entry of its message.
      // The line "Model changed to …" (#203) is not part of a turn.
      final lastOfTurn = entry is! ModelChanged &&
          (i == transcript.length - 1 ||
              transcript[i + 1] is UserMessage ||
              transcript[i + 1] is ModelChanged);
      switch (entry) {
        case ModelChanged():
          children.add(
            Padding(
              key: ValueKey('chat-model-changed-$i'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                entry.text,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          );
        case UserMessage():
          children.add(
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                key: ValueKey('chat-user-$i'),
                margin: const EdgeInsets.fromLTRB(48, 8, 8, 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(entry.text),
              ),
            ),
          );
        case AssistantMessage():
          // The provider's own web searches (#137).
          for (final (j, result) in entry.searches.indexed) {
            children.add(
              _ToolCallTile(key: ValueKey('chat-search-$i-$j'), result: result),
            );
          }
          if (entry.text.trim().isNotEmpty) {
            final writer = widget.writer;
            children.add(
              Container(
                key: ValueKey('chat-answer-$i'),
                margin: const EdgeInsets.fromLTRB(8, 8, 24, 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Selectable, as the Copy button copies it all (#94).
                    SelectionArea(
                      child: OrgText(entry.text.trim(), onLinkTap: _openLink),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.model,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        IconButton(
                          key: ValueKey('chat-copy-$i'),
                          tooltip: 'Copy',
                          icon: const Icon(Icons.copy_outlined, size: 18),
                          onPressed: () => copyText(context, entry.text.trim()),
                        ),
                        if (writer != null && entry.toolCalls.isEmpty)
                          TextButton.icon(
                            key: ValueKey('chat-save-$i'),
                            // One at a time, and not while the chat sends,
                            // waits for "Send again" or undoes (#145).
                            onPressed: _sending ||
                                    _preparing != null ||
                                    _undoing != null ||
                                    (session?.waiting ?? false)
                                ? null
                                : () => _saveAsNode(writer, i),
                            icon: _preparing == i
                                ? const SizedBox.square(
                                    key: ValueKey('chat-save-wait'),
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.note_add_outlined,
                                    size: 18),
                            label: const Text('Save as new node'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          } else if (entry.toolCalls.isEmpty &&
              entry.searches.isEmpty &&
              !entry.paused) {
            // A final answer without text: say so rather than show nothing.
            children.add(
              Padding(
                key: ValueKey('chat-empty-$i'),
                padding: const EdgeInsets.fromLTRB(16, 8, 24, 4),
                child: Text(
                  'The model sent no text.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            );
          }
        case ToolResults():
          for (final (j, result) in entry.results.indexed) {
            children.add(
              _ToolCallTile(key: ValueKey('chat-tool-$i-$j'), result: result),
            );
            // The image create_image made (#129).
            if (result.image case final image?) {
              children.add(
                Padding(
                  key: ValueKey('chat-image-$i-$j'),
                  padding: const EdgeInsets.fromLTRB(16, 4, 48, 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      Uint8List.fromList(image.bytes),
                      fit: BoxFit.contain,
                      errorBuilder: (context, _, _) =>
                          const Text('The image cannot be shown here.'),
                    ),
                  ),
                ),
              );
            }
            final callId = result.call.id;
            if (_setProposals[callId] case final proposed?) {
              final set = _sets[callId];
              final saved = set?.entries
                      .where((e) => e.state == EntryState.saved)
                      .length ??
                  0;
              children.add(
                Card(
                  key: ValueKey('chat-change-set-$i-$j'),
                  margin: const EdgeInsets.fromLTRB(8, 4, 24, 4),
                  child: ListTile(
                    leading: const Icon(Icons.library_books_outlined),
                    title: Text(
                        'Changes to ${proposed.edits.length} notes'),
                    subtitle: Text(set == null
                        ? (proposed.summary.isEmpty
                            ? 'Not saved; review them first.'
                            : proposed.summary)
                        : '$saved saved'),
                    trailing: TextButton(
                      onPressed: () => _reviewSet(callId),
                      child: const Text('Review'),
                    ),
                  ),
                ),
              );
            }
            if (_proposals[callId] case final proposal?) {
              final title = widget.graph.value.nodes[proposal.nodeId]
                      ?.displayTitle ??
                  proposal.nodeId;
              final status = _proposalStatus[callId];
              children.add(
                Card(
                  key: ValueKey('chat-proposal-$i-$j'),
                  margin: const EdgeInsets.fromLTRB(8, 4, 24, 4),
                  child: ListTile(
                    leading: const Icon(Icons.edit_note_outlined),
                    title: Text(
                      proposal.mode == EditMode.append
                          ? 'Add to "$title"'
                          : 'Change the text of "$title"',
                    ),
                    subtitle: Text(status ??
                        (proposal.reason.isEmpty
                            ? 'Not saved; review it first.'
                            : proposal.reason)),
                    trailing: status != null
                        ? const Icon(Icons.check)
                        : TextButton(
                            onPressed: () => _review(callId),
                            child: const Text('Review'),
                          ),
                  ),
                ),
              );
            }
          }
      }
      // After the answer: what the agent changed for this message.
      final changes = _turnChanges[turn];
      if (lastOfTurn &&
          !(_sending && i == transcript.length - 1) &&
          changes != null &&
          !changes.isEmpty) {
        children.add(_agentSummary(turn, changes));
      }
    }
    // My message while the chat waits for a place to work in.
    if (_chat.pendingText case final pending?) {
      children.add(
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            key: const ValueKey('chat-pending'),
            margin: const EdgeInsets.fromLTRB(48, 8, 8, 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(pending),
          ),
        ),
      );
    }
    if (_error case final error?) {
      children.add(
        Card(
          key: const ValueKey('chat-error'),
          color: colors.errorContainer,
          margin: const EdgeInsets.all(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ErrorText(
                  _errorDetail?.message == error
                      ? _errorDetail!
                      : ErrorReport(error),
                  textKey: const ValueKey('chat-error-text'),
                  copyKey: const ValueKey('chat-error-copy'),
                  color: colors.onErrorContainer,
                ),
                if (session?.waiting ?? false)
                  Row(
                    children: [
                      TextButton(
                        onPressed:
                            _sending || _preparing != null ? null : _resume,
                        child: const Text('Send again'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (_chat.transcript.isNotEmpty) {
      final usage = _chat.usage;
      final size = _chat.characters;
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tokens in this chat: ${usage.input} in, of them '
                '${usage.cached} from the cache, ${usage.output} out.',
                key: const ValueKey('chat-usage'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              // Every message sends the whole chat again (#201).
              Text(
                'Size of this chat: about $size characters.',
                key: const ValueKey('chat-size'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (size > longChatCharacters)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'This chat is long, and every message sends all of it '
                    'again. A new chat costs less.',
                    key: const ValueKey('chat-long'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('chat-list'),
      controller: _scroll,
      children: children,
    );
  }

  /// The summary of what the agent changed for the message at [turn]:
  /// each note, to open or to see the change as a diff, and "Undo all".
  Widget _agentSummary(int turn, AgentChanges changes) {
    final undone = changes.undone;
    return Card(
      key: ValueKey('agent-summary-$turn'),
      margin: const EdgeInsets.fromLTRB(8, 4, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.auto_fix_high_outlined),
            title: Text(changes.summary, key: ValueKey('agent-counts-$turn')),
            subtitle: undone == null ? null : Text(undoMessage(undone)),
          ),
          for (final path in changes.files)
            ListTile(
              key: ValueKey('agent-file-$path'),
              dense: true,
              title: Text(changes.first(path).title),
              subtitle: Text(
                '${changes.deletedFiles.contains(path) ? 'Deleted' : changes.createdFiles.contains(path) ? 'Created' : 'Changed'}'
                '${switch (undone?[path]) {
                  UndoOutcome.restored => ', restored',
                  UndoOutcome.deleted => ', deleted again',
                  UndoOutcome.recreated => ', back again',
                  UndoOutcome.changedSince => ', changed since: kept',
                  UndoOutcome.otherFolder =>
                    ', in the folder opened before: kept',
                  UndoOutcome.failed => ', could not be undone',
                  null => ''
                }}',
              ),
              onTap: () {
                final id = changes.first(path).nodeId;
                if (widget.graph.value.nodes.containsKey(id)) {
                  widget.openNode?.call(context, id);
                } else {
                  _tell('That note is not in the graph now.');
                }
              },
              trailing: IconButton(
                tooltip: 'Show the change',
                icon: const Icon(Icons.difference_outlined),
                onPressed: () => DiffScreen.view(
                  context,
                  title: changes.first(path).title,
                  before: changes.before(path) ?? '',
                  after: changes.after(path) ?? '',
                ),
              ),
            ),
          if (changes.canUndo)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextButton.icon(
                key: ValueKey('agent-undo-$turn'),
                onPressed:
                    _sending || _undoing != null ? null : () => _undo(turn),
                icon: const Icon(Icons.undo),
                label: Text(undone == null
                    ? 'Undo all changes of this message'
                    : 'Try the rest again'),
              ),
            ),
        ],
      ),
    );
  }

  /// Undoes every change the agent made for the message at [turn].
  Future<void> _undo(int turn) async {
    final changes = _turnChanges[turn];
    final editor = widget.writer?.editor;
    if (changes == null || editor == null) return;
    setState(() => _undoing = turn);
    try {
      final outcome = await undoAndLog(changes, editor, widget.agentLog,
          create: widget.writer?.create);
      if (mounted) _tell(undoMessage(outcome));
    } finally {
      if (mounted) setState(() => _undoing = null);
    }
  }

  Widget _composer(BuildContext context) {
    // A turn that failed is finished with "Send again" or a new chat
    // first, so a new question does not join it.
    final ready =
        _session != null &&
        _setupProblem == null &&
        !_sending &&
        _preparing == null &&
        !(_session?.waiting ?? false);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('chat-input'),
                controller: _input,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Ask about your notes',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              icon: const Icon(Icons.send),
              onPressed: ready ? _send : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// A tool call, collapsed: which tool, with what; opened, its result.
class _ToolCallTile extends StatelessWidget {
  const _ToolCallTile({super.key, required this.result});

  final ToolResult result;

  @override
  Widget build(BuildContext context) {
    final call = result.call;
    final args = [
      for (final MapEntry(:key, :value) in call.input.entries) '$key: $value',
    ].join(', ');
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: const Icon(Icons.build_outlined, size: 18),
        title: Text(
          '${call.name.replaceFirst('org_roam_', '')}($args)',
          style: theme.textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectableText(
              result.content,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('chat-tool-copy'),
              // The call and its result, for example to report an error.
              onPressed: () => copyText(
                  context, '${call.name}($args)\n\n${result.content}'),
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: const Text('Copy'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Puts [text] on the clipboard and says so (#94).
Future<void> copyText(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('Copied.')));
}

/// Throws [ToolError] if a note of [ids] got a hidden tag since the index
/// was built, as the read tools check it: its title must not reach the AI.
Future<void> _checkStillVisible(
    Chat chat, NoteTextReader readNote, List<String> ids) async {
  final graph = chat.session?.tools.graph;
  if (graph == null) return;
  for (final id in ids) {
    final node = graph.nodes[id];
    if (node == null) continue;
    final text = await readNote(node.file);
    if (text != null && chat.visibility.hidesInText(node, text)) {
      throw ToolError('There is no note with the ID $id that you may see.');
    }
  }
}

/// Records an edit the AI proposes (#39); the tool writes nothing. It
/// works on the chat, not on the screen, which may be closed (#201).
Future<String> _proposeEdit(
    Chat chat, NoteTextReader readNote, ToolCall call) async {
  final session = chat.session;
  if (session == null) return 'Error: the chat has ended.';
  try {
    final proposal = proposalFrom(call.input, session.tools.graph);
    await _checkStillVisible(chat, readNote, [proposal.nodeId]);
    chat.proposals[call.id] = proposal;
    final title = session.tools.graph.nodes[proposal.nodeId]!.displayTitle;
    return 'Recorded. I review the change to "$title" as a diff in the '
        'app before anything is saved; it is not saved yet.';
  } on ToolError catch (e) {
    return 'Error: ${e.message}';
  }
}

/// Records a change set the AI proposes (#76); the tool writes nothing.
Future<String> _proposeEditSet(
    Chat chat, NoteTextReader readNote, ToolCall call) async {
  final session = chat.session;
  if (session == null) return 'Error: the chat has ended.';
  try {
    final edits = proposalsFrom(call.input, session.tools.graph);
    await _checkStillVisible(chat, readNote, [for (final e in edits) e.nodeId]);
    final files = {
      for (final e in edits) session.tools.graph.nodes[e.nodeId]!.file,
    };
    if (files.length != edits.length) {
      return 'Error: two edits are for the same file; give one edit per '
          'file, with both changes in it.';
    }
    if (files.length > chat.maxFiles) {
      return 'Error: the set has ${files.length} notes; the limit is '
          '${chat.maxFiles}. Propose fewer at a time.';
    }
    final summary = call.input['summary'];
    chat.setProposals[call.id] =
        (edits: edits, summary: summary is String ? summary.trim() : '');
    return 'Recorded a change set of ${edits.length} notes. I review each '
        'diff in the app before anything is saved; nothing is saved yet.';
  } on ToolError catch (e) {
    return 'Error: ${e.message}';
  }
}
