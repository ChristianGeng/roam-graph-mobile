/// A chat with a model that reads the graph through the AI tools (#58),
/// over one of two APIs (#59): Anthropic's Messages API or an
/// OpenAI-compatible Chat Completions API.
///
/// The app sends a request only when the user sends a message, and then
/// one per tool round: the conversation, the tools' descriptions and the
/// tool results the model asked for. Nothing is sent in the background.
///
/// Pure Dart (no Flutter); HTTP goes through [HttpPost], which tests
/// replace.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_providers.dart';
import 'ai_tools.dart';

/// What the model is told before the conversation. It never changes, so
/// every request starts with the same bytes and the provider can cache
/// it (prompt caching); the current node goes into the first message.
const systemPrompt =
    'You are an assistant inside Roam Graph, an Android app for my '
    'org-roam notes: Org mode files, linked by IDs. Use the tools to look '
    'things up instead of guessing; they read the app\'s index of my notes. '
    'Some notes are hidden from you by their tags; the tools do not show '
    'them, so the graph you see is not complete. When you name a note, link '
    'it in Org syntax with the ID a tool gave you: [[id:<ID>][<title>]]. '
    'When I ask you to write a note, write it in Org mode with its title on '
    'the first line; I review it before it is saved. Keep tool calls few '
    'and answers short. Answer in the language I write in.';

/// An HTTP response.
class HttpReply {
  const HttpReply(this.status, this.body);

  final int status;
  final String body;
}

/// Sends a POST request; tests replace it.
typedef HttpPost = Future<HttpReply> Function(
    Uri url, Map<String, String> headers, String body);

/// [HttpPost] with `dart:io`. The only network use of the app (decision
/// 45).
Future<HttpReply> postWithDartIo(
    Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'RoamGraph';
  try {
    final request = await client.postUrl(url);
    // A redirect could send the conversation to another host.
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.add(utf8.encode(body));
    final response =
        await request.close().timeout(const Duration(minutes: 4));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(minutes: 4));
    return HttpReply(response.statusCode, text);
  } finally {
    client.close(force: true);
  }
}

/// Something the user can act on, in plain words.
class AiError implements Exception {
  const AiError(this.message, {this.status});

  final String message;

  /// The HTTP status the provider answered with, where it refused the
  /// request.
  final int? status;

  @override
  String toString() => message;
}

/// Where and how to reach a model.
class ProviderConfig {
  const ProviderConfig({
    required this.name,
    required this.api,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.euOnly = false,
    this.maxOutputTokens = 8192,
    this.keyRequired = true,
  });

  /// The provider's name, for messages.
  final String name;
  final ApiKind api;
  final String baseUrl;
  final String model;
  final String apiKey;

  /// Vercel AI Gateway's EU region.
  final bool euOnly;

  /// The most tokens one answer may have, thinking included.
  final int maxOutputTokens;

  /// False for a provider that needs no key, such as a local Ollama.
  final bool keyRequired;

  ProviderConfig withModel(String model, {bool? euOnly}) => ProviderConfig(
        name: name,
        api: api,
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
        euOnly: euOnly ?? this.euOnly,
        maxOutputTokens: maxOutputTokens,
        keyRequired: keyRequired,
      );
}

/// Tokens used, as the providers report them.
class TokenUsage {
  const TokenUsage({this.input = 0, this.cached = 0, this.output = 0});

  static const zero = TokenUsage();

  /// All input tokens, those read from the cache included.
  final int input;

  /// Of [input], those read from the provider's cache, at a lower price.
  final int cached;
  final int output;

  TokenUsage operator +(TokenUsage other) => TokenUsage(
        input: input + other.input,
        cached: cached + other.cached,
        output: output + other.output,
      );
}

/// A tool the model asked for.
class ToolCall {
  const ToolCall(this.id, this.name, this.input, {this.badArguments});

  final String id;
  final String name;
  final Map<String, Object?> input;

  /// Set when the arguments were not readable JSON.
  final String? badArguments;
}

/// An image a tool made, shown to the model with the tool's result so it
/// can check it (#129).
class ToolImage {
  const ToolImage(this.bytes, this.mediaType);

  final List<int> bytes;

  /// `image/png`, `image/jpeg` or `image/webp`.
  final String mediaType;

  String get base64Data => base64Encode(bytes);
}

/// A tool's result, for the model.
class ToolResult {
  const ToolResult(this.call, this.content, {this.image});

  final ToolCall call;
  final String content;

  /// An image to show the model with [content].
  final ToolImage? image;
}

/// The text that tells the model it could not be shown the image.
const imageNotShown = '(The image could not be shown to you: this model '
    'does not take images. Do not judge it; tell me to look at it.)';

/// The index of the first entry of the current message: images of tool
/// results before it are not sent again, so they cost nothing later.
int currentMessageStart(List<ChatEntry> transcript) {
  for (var i = transcript.length - 1; i >= 0; i--) {
    if (transcript[i] is UserMessage) return i;
  }
  return 0;
}

/// One entry of a conversation.
sealed class ChatEntry {
  const ChatEntry();
}

/// My message. [context] goes before it to the model, not on screen: the
/// node the chat was opened from.
class UserMessage extends ChatEntry {
  const UserMessage(this.text, {this.context});

  final String text;
  final String? context;

  String get forModel => context == null ? text : '$context\n\n$text';
}

/// The model's answer: text, tool calls, or both.
class AssistantMessage extends ChatEntry {
  const AssistantMessage({
    required this.text,
    this.toolCalls = const [],
    required this.model,
    this.raw,
  });

  final String text;
  final List<ToolCall> toolCalls;

  /// The model that answered.
  final String model;

  /// The answer as the API returned it, sent back as it was: Anthropic's
  /// content blocks keep their thinking and its signature, which the API
  /// requires back with tool results.
  final Object? raw;
}

/// The results of one round of tool calls.
class ToolResults extends ChatEntry {
  const ToolResults(this.results);

  final List<ToolResult> results;
}

/// A request as the app sends it.
class ApiRequest {
  const ApiRequest(this.url, this.headers, this.body);

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

/// What one request returned.
class ApiReply {
  const ApiReply(this.message, this.usage, {this.cut = false});

  final AssistantMessage message;
  final TokenUsage usage;

  /// True when the answer stopped at [ProviderConfig.maxOutputTokens].
  final bool cut;
}

/// Builds requests for one API and reads its answers.
abstract class ModelApi {
  const ModelApi();

  factory ModelApi.of(ApiKind kind) => switch (kind) {
        ApiKind.anthropic => const AnthropicApi(),
        ApiKind.openAi => const OpenAiApi(),
      };

  /// The request for [transcript]. It starts with the same bytes in every
  /// round: the system prompt, the tools in their fixed order, then the
  /// conversation so far, which only grows.
  ApiRequest request(
      ProviderConfig config, List<AiTool> tools, List<ChatEntry> transcript,
      {String system = systemPrompt, bool images = true});

  /// Reads a successful answer.
  ApiReply read(ProviderConfig config, Map<String, Object?> json);
}

String _url(String base, String path) {
  var b = base.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  return '$b$path';
}

const _ephemeral = {'type': 'ephemeral'};

/// Anthropic's Messages API (also Claude on AWS Bedrock's).
class AnthropicApi extends ModelApi {
  const AnthropicApi();

  @override
  ApiRequest request(
      ProviderConfig config, List<AiTool> tools, List<ChatEntry> transcript,
      {String system = systemPrompt, bool images = true}) {
    final current = currentMessageStart(transcript);
    final messages = <Map<String, Object?>>[];
    void addUser(List<Map<String, Object?>> blocks) {
      // Tool results and my next message go into one user message.
      if (messages.isNotEmpty && messages.last['role'] == 'user') {
        (messages.last['content'] as List).addAll(blocks);
      } else {
        messages.add({'role': 'user', 'content': blocks});
      }
    }

    for (final (index, entry) in transcript.indexed) {
      switch (entry) {
        case UserMessage():
          addUser([
            {'type': 'text', 'text': entry.forModel},
          ]);
        case AssistantMessage():
          messages.add({
            'role': 'assistant',
            'content': entry.raw ??
                [
                  if (entry.text.isNotEmpty) {'type': 'text', 'text': entry.text},
                  for (final call in entry.toolCalls)
                    {
                      'type': 'tool_use',
                      'id': call.id,
                      'name': call.name,
                      'input': call.input,
                    },
                ],
          });
        case ToolResults():
          addUser([
            for (final result in entry.results)
              {
                'type': 'tool_result',
                'tool_use_id': result.call.id,
                'content': switch (result.image) {
                  // Only in the current message, and only to a model that
                  // takes images (#129).
                  final image? when index >= current && images => [
                      {'type': 'text', 'text': result.content},
                      {
                        'type': 'image',
                        'source': {
                          'type': 'base64',
                          'media_type': image.mediaType,
                          'data': image.base64Data,
                        },
                      },
                    ],
                  final _? when index >= current =>
                    '${result.content}\n\n$imageNotShown',
                  _ => result.content,
                },
              },
          ]);
      }
    }
    // Cache breakpoints: after the system prompt (tools and system), and
    // at the end of the conversation, so the next round reads all of this
    // from the cache. Earlier ends are found again by the API.
    if (messages.isNotEmpty) {
      final last = (messages.last['content'] as List).cast<Object?>();
      final block = Map<String, Object?>.of(last.last as Map<String, Object?>);
      block['cache_control'] = _ephemeral;
      messages.last = {
        ...messages.last,
        'content': [...last.sublist(0, last.length - 1), block],
      };
    }
    return ApiRequest(
      Uri.parse(_url(config.baseUrl, '/v1/messages')),
      {
        'content-type': 'application/json',
        'anthropic-version': '2023-06-01',
        if (config.apiKey.isNotEmpty) 'x-api-key': config.apiKey,
      },
      {
        'model': config.model,
        'max_tokens': config.maxOutputTokens,
        'tools': [
          for (final tool in tools)
            {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.parameters,
            },
        ],
        'system': [
          {'type': 'text', 'text': system, 'cache_control': _ephemeral},
        ],
        'messages': messages,
      },
    );
  }

  @override
  ApiReply read(ProviderConfig config, Map<String, Object?> json) {
    final content = (json['content'] as List? ?? const []).cast<Object?>();
    final text = StringBuffer();
    final calls = <ToolCall>[];
    for (final block in content.whereType<Map<String, Object?>>()) {
      switch (block['type']) {
        case 'text':
          text.write(block['text'] as String? ?? '');
        case 'tool_use':
          calls.add(ToolCall(
            block['id'] as String,
            block['name'] as String,
            (block['input'] as Map?)?.cast<String, Object?>() ?? const {},
          ));
      }
    }
    final usage = (json['usage'] as Map?)?.cast<String, Object?>() ?? const {};
    int n(String key) => (usage[key] as num?)?.toInt() ?? 0;
    return ApiReply(
      AssistantMessage(
        text: text.toString(),
        toolCalls: calls,
        model: json['model'] as String? ?? config.model,
        raw: content,
      ),
      TokenUsage(
        input: n('input_tokens') +
            n('cache_read_input_tokens') +
            n('cache_creation_input_tokens'),
        cached: n('cache_read_input_tokens'),
        output: n('output_tokens'),
      ),
      cut: json['stop_reason'] == 'max_tokens',
    );
  }
}

/// OpenAI's Chat Completions API, which many providers offer.
class OpenAiApi extends ModelApi {
  const OpenAiApi();

  @override
  ApiRequest request(
      ProviderConfig config, List<AiTool> tools, List<ChatEntry> transcript,
      {String system = systemPrompt, bool images = true}) {
    final current = currentMessageStart(transcript);
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': system},
    ];
    for (final (index, entry) in transcript.indexed) {
      switch (entry) {
        case UserMessage():
          messages.add({'role': 'user', 'content': entry.forModel});
        case AssistantMessage():
          final raw = entry.raw;
          // Mistral answers with a list of parts (thinking and text) and
          // wants the whole message replayed, thinking included.
          final parts = raw is Map &&
                  raw['content'] is List &&
                  (raw['content'] as List).isNotEmpty
              ? raw['content']
              : null;
          final content =
              parts ?? (entry.text.isEmpty ? null : entry.text);
          // An answer with no content and no tool calls is rejected by
          // Mistral ("must have either content or tool_calls"): leave it out.
          if (content == null && entry.toolCalls.isEmpty) continue;
          messages.add({
            'role': 'assistant',
            'content': content,
            if (entry.toolCalls.isNotEmpty)
              'tool_calls': [
                for (final call in entry.toolCalls)
                  {
                    'id': call.id,
                    'type': 'function',
                    'function': {
                      'name': call.name,
                      'arguments': call.badArguments ?? jsonEncode(call.input),
                    },
                  },
              ],
            // DeepSeek wants its reasoning back within a tool loop.
            if (raw is Map && raw['reasoning_content'] is String)
              'reasoning_content': raw['reasoning_content'],
          });
        case ToolResults():
          final shown = <ToolResult>[];
          for (final result in entry.results) {
            final image = index >= current ? result.image : null;
            if (image != null && images) shown.add(result);
            messages.add({
              'role': 'tool',
              'tool_call_id': result.call.id,
              'content': image != null && !images
                  ? '${result.content}\n\n$imageNotShown'
                  : result.content,
            });
          }
          // A tool message holds only text in this API: the images follow
          // in a message of mine, after all the tool results (#129).
          if (shown.isNotEmpty) {
            messages.add({
              'role': 'user',
              'content': [
                for (final result in shown) ...[
                  {
                    'type': 'text',
                    'text': 'The image ${result.call.name} made '
                        '(${result.call.id}):',
                  },
                  {
                    'type': 'image_url',
                    'image_url': {
                      'url': 'data:${result.image!.mediaType};base64,'
                          '${result.image!.base64Data}',
                    },
                  },
                ],
              ],
            });
          }
      }
    }
    return ApiRequest(
      Uri.parse(_url(config.baseUrl, '/chat/completions')),
      {
        'content-type': 'application/json',
        if (config.apiKey.isNotEmpty) 'authorization': 'Bearer ${config.apiKey}',
      },
      {
        'model': config.model,
        'max_tokens': config.maxOutputTokens,
        'tools': [
          for (final tool in tools)
            {
              'type': 'function',
              'function': {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
              },
            },
        ],
        'messages': messages,
        // Vercel AI Gateway: inference and stored data in the EU.
        if (config.euOnly)
          'providerOptions': {
            'gateway': {
              'inferenceRegion': {'scope': 'zone', 'geoRegion': 'eu'},
            },
          },
      },
    );
  }

  @override
  ApiReply read(ProviderConfig config, Map<String, Object?> json) {
    final choices = (json['choices'] as List?)?.cast<Object?>() ?? const [];
    if (choices.isEmpty || choices.first is! Map) {
      throw const AiError('The provider sent an answer without a message.');
    }
    final choice = (choices.first as Map).cast<String, Object?>();
    final message =
        (choice['message'] as Map?)?.cast<String, Object?>() ?? const {};
    final calls = <ToolCall>[];
    for (final call in (message['tool_calls'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()) {
      final function = (call['function'] as Map?) ?? const {};
      final arguments = function['arguments'];
      Map<String, Object?>? input;
      if (arguments is Map) {
        input = arguments.cast<String, Object?>();
      } else if (arguments is String) {
        try {
          final decoded = jsonDecode(arguments.isEmpty ? '{}' : arguments);
          if (decoded is Map) input = decoded.cast<String, Object?>();
        } on FormatException {
          input = null;
        }
      }
      calls.add(ToolCall(
        call['id'] as String? ?? 'call_${calls.length}',
        function['name'] as String? ?? '',
        input ?? const {},
        badArguments: input == null ? '$arguments' : null,
      ));
    }
    final usage = (json['usage'] as Map?)?.cast<String, Object?>() ?? const {};
    final details =
        (usage['prompt_tokens_details'] as Map?)?.cast<String, Object?>();
    int n(Object? value) => (value as num?)?.toInt() ?? 0;
    return ApiReply(
      AssistantMessage(
        text: contentText(message['content']),
        toolCalls: calls,
        model: json['model'] as String? ?? config.model,
        raw: message,
      ),
      TokenUsage(
        input: n(usage['prompt_tokens']),
        // OpenAI, Qwen and others report it here; DeepSeek elsewhere.
        cached: n(details?['cached_tokens'] ?? usage['prompt_cache_hit_tokens']),
        output: n(usage['completion_tokens']),
      ),
      cut: choice['finish_reason'] == 'length',
    );
  }
}

/// The text of an OpenAI-style `content`: a string, or a list of parts, of
/// which the `text` parts are joined. Other parts, such as Mistral's
/// `thinking`, are not shown; they stay in the raw message.
String contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  return [
    for (final part in content)
      if (part is Map && part['type'] == 'text' && part['text'] is String)
        part['text'] as String,
  ].join();
}

/// One chat: the conversation, and the loop that runs the tools the model
/// asks for until it answers.
class ChatSession {
  ChatSession({
    required this.tools,
    required ProviderConfig config,
    this.post = postWithDartIo,
    this.maxToolRounds = 10,
    this.toolList,
    this.handlers = const {},
    this.system = systemPrompt,
    this.toolImage,
  }) : _config = config;

  /// The image a handler made for a call, if any, to show the model with
  /// the call's result (#129).
  final ToolImage? Function(ToolCall call)? toolImage;

  /// False once the model refused a request with an image: images are no
  /// longer sent in this chat (#129).
  bool _images = true;

  /// The system prompt: [systemPrompt], or the agent's (#82).
  final String system;

  /// The tools; the chat screen replaces them when the graph or the
  /// hidden tags change.
  RoamTools tools;
  final HttpPost post;

  /// The most tool rounds for one message, so a confused model cannot loop
  /// without end.
  final int maxToolRounds;

  /// The tools offered; all of [aiTools] by default.
  final List<AiTool>? toolList;

  /// Tools the chat runs itself rather than [tools], by name, such as
  /// `propose_edit` (#39), which records a proposal for the user to
  /// review. Each gets the call and returns the text for the model.
  final Map<String, Future<String> Function(ToolCall call)> handlers;

  ProviderConfig _config;
  ProviderConfig get config => _config;

  final transcript = <ChatEntry>[];
  TokenUsage usage = TokenUsage.zero;

  /// The last request, for tests and the chat's details.
  ApiRequest? lastRequest;

  /// Switches the model for the rest of this chat (#60).
  set model(String model) => _config = _config.withModel(model);

  ModelApi get _api => ModelApi.of(_config.api);

  /// Tool rounds run for the current message; [send] starts again at 0,
  /// [resume] goes on counting.
  int _rounds = 0;

  bool _cancelled = false;

  /// Stops this chat: no further tool runs and no further requests, for
  /// example when its screen closes during a request.
  void cancel() => _cancelled = true;

  /// Sends [text] and runs tool rounds until the model answers.
  /// [onUpdate] runs after each step. Throws [AiError]; then [resume] tries
  /// again from where it stopped.
  Future<void> send(String text,
      {String? context, void Function()? onUpdate}) async {
    final first = !transcript.any((e) => e is UserMessage);
    transcript.add(UserMessage(text, context: first ? context : null));
    _rounds = 0;
    onUpdate?.call();
    await resume(onUpdate: onUpdate);
  }

  /// Whether the conversation waits for the model: my message or tool
  /// results are last.
  bool get waiting =>
      transcript.isNotEmpty && transcript.last is! AssistantMessage;

  /// Continues after an error: sends the conversation again. The tool
  /// rounds of the message count on, so a retry gets no new rounds.
  Future<void> resume({void Function()? onUpdate}) async {
    final offered = toolList ?? aiTools;
    while (waiting && !_cancelled) {
      ApiReply reply;
      try {
        reply = await _request(offered);
      } on AiError catch (e) {
        // A model that does not take images refuses the request: once,
        // the same again without them (#129).
        if (!_images || !_imageSent || !_refusedRequest(e)) rethrow;
        _images = false;
        if (_cancelled) return;
        reply = await _request(offered);
      }
      if (_cancelled) return;
      usage += reply.usage;
      final message = reply.message;
      if (reply.cut) {
        // Not kept, so "Send again" asks again; a part of an answer, or of
        // a tool call, is of no use.
        throw AiError('The answer stopped at ${_config.maxOutputTokens} '
            'tokens and was dropped. Raise "Most tokens per answer" in AI '
            'settings and start a new chat, or ask for less.');
      }
      if (message.toolCalls.isNotEmpty && _rounds >= maxToolRounds) {
        // More tool calls than allowed: keep the text, run nothing.
        transcript.add(AssistantMessage(
          text: message.text.isEmpty
              ? '(Stopped after $maxToolRounds tool rounds.)'
              : message.text,
          model: message.model,
        ));
        onUpdate?.call();
        return;
      }
      transcript.add(message);
      onUpdate?.call();
      if (message.toolCalls.isEmpty) return;
      _rounds++;
      final last = _rounds >= maxToolRounds;
      final results = <ToolResult>[];
      for (final call in message.toolCalls) {
        if (_cancelled) return;
        final content = await _runTool(call);
        results.add(ToolResult(call, content, image: toolImage?.call(call)));
      }
      if (last) {
        final end = results.removeLast();
        results.add(ToolResult(
            end.call,
            '${end.content}\n\n(That was the last of the $maxToolRounds '
            'tool rounds the app allows for one message: answer now, with '
            'what you have.)',
            image: end.image));
      }
      transcript.add(ToolResults(results));
      onUpdate?.call();
    }
  }

  /// The result of [call] for the model; every call gets one, also when
  /// the tool fails, as the APIs require.
  Future<String> _runTool(ToolCall call) async {
    if (call.badArguments != null) {
      return 'Error: the arguments are not valid JSON: ${call.badArguments}';
    }
    try {
      if (handlers[call.name] case final handler?) return await handler(call);
      return await tools.call(call.name, call.input);
    } catch (e) {
      return 'Error: the tool failed: $e';
    }
  }

  /// Whether the current message has an image for the model.
  bool get _imageSent {
    final current = currentMessageStart(transcript);
    for (final entry in transcript.skip(current)) {
      if (entry is ToolResults && entry.results.any((r) => r.image != null)) {
        return true;
      }
    }
    return false;
  }

  static bool _refusedRequest(AiError e) =>
      e.status == 400 || e.status == 415 || e.status == 422;

  Future<ApiReply> _request(List<AiTool> offered) async {
    final config = _config;
    if (config.model.trim().isEmpty) {
      throw AiError('No model is set for ${config.name}. Choose one in AI '
          'settings.');
    }
    if (config.keyRequired && config.apiKey.isEmpty) {
      throw AiError('No API key for ${config.name}. Enter it in AI '
          'settings.');
    }
    if (config.baseUrl.trim().isEmpty) {
      throw AiError('No base URL for ${config.name}. Enter it in AI '
          'settings.');
    }
    final request = _api.request(config, offered, transcript,
        system: system, images: _images);
    if (request.url.scheme != 'https' && config.apiKey.isNotEmpty) {
      throw AiError('The app sends an API key only over HTTPS. Use an '
          'https:// base URL for ${config.name}, or remove the key for a '
          'local server without one.');
    }
    lastRequest = request;
    final json =
        await postJson(config, request.url, request.headers, request.body, post);
    return _api.read(config, json);
  }
}

/// POSTs [body] as JSON to [url] for [config]'s provider and returns the
/// JSON object it answers with; every failure is an [AiError] in plain
/// words. Also for images (#112).
Future<Map<String, Object?>> postJson(ProviderConfig config, Uri url,
    Map<String, String> headers, Object? body, HttpPost post) async {
  HttpReply reply;
  try {
    reply = await post(url, headers, jsonEncode(body));
  } on SocketException catch (e) {
    throw AiError('No connection to ${url.host}: ${e.message}. '
        'Check the network.');
  } on HandshakeException catch (e) {
    throw AiError('No secure connection to ${url.host}: ${e.message}.');
  } on TimeoutException {
    throw AiError('${url.host} did not answer in time. Try again.');
  } on HttpException catch (e) {
    throw AiError('The connection to ${url.host} failed: ${e.message}.');
  }
  Object? json;
  try {
    json = jsonDecode(reply.body);
  } on FormatException {
    json = null;
  }
  if (reply.status >= 300 && reply.status < 400) {
    throw AiError('${config.name} answered with a redirect (HTTP '
        '${reply.status}), which the app does not follow, so nothing goes '
        'to another host. Check the base URL.');
  }
  if (reply.status < 200 || reply.status >= 300) {
    throw AiError(_httpError(config, reply.status, _message(json, reply.body)),
        status: reply.status);
  }
  if (json is! Map) {
    throw AiError('${config.name} sent an answer the app cannot read.');
  }
  return json.cast<String, Object?>();
}

/// The provider's own error message, from the shapes the APIs use.
String _message(Object? json, String body) {
  if (json is Map) {
    final error = json['error'];
    if (error is Map && error['message'] is String) return error['message'];
    if (error is String) return error;
    if (json['message'] is String) return json['message'] as String;
    if (json['detail'] is String) return json['detail'] as String;
  }
  final text = body.trim();
  return text.length > 300 ? '${text.substring(0, 300)}…' : text;
}

String _httpError(ProviderConfig config, int status, String message) {
  final detail = message.isEmpty ? '' : ' $message';
  return switch (status) {
    401 || 403 => '${config.name} refused the API key (HTTP $status). Check '
        'it in AI settings.$detail',
    429 => 'Too many requests, or no credit left at ${config.name} (HTTP '
        '429). Wait a moment, or check the account.$detail',
    404 => 'Not found at ${config.name} (HTTP 404). Check the base URL and '
        'the model "${config.model}".$detail',
    400 when _saysNoTools(message) =>
      '${config.name} answered with an error (HTTP 400).$detail The model '
          '"${config.model}" may not support tools, which the chat needs; '
          'if so, choose another model.',
    _ => '${config.name} answered with an error (HTTP $status).$detail',
  };
}

/// Whether a provider's error says that the model cannot use tools, and
/// not just mentions them (Mistral: "must have either content or
/// tool_calls").
bool _saysNoTools(String message) => RegExp(
      r"(does not|doesn't|do not|don't) support (tools|tool use|tool calling|function calling)"
      r'|(tools?|tool use|tool calling|function calling) (is |are )?not supported'
      r'|no endpoints found that support tool use',
      caseSensitive: false,
    ).hasMatch(message);
