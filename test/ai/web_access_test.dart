import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/ai/web_access.dart';

import 'ai_chat_test.dart' show FakeServer, anthropic, anthropicReply, openAiReply;
import 'ai_settings_test.dart'
    show MemoryAiSettingsStore, pumpIn, scrollTo;
import 'ai_visibility_test.dart' show graphOf, notes;

/// Names and the addresses they stand for, as DNS would answer.
final names = {
  'example.org': [InternetAddress('93.184.215.14')],
  'inside.example': [InternetAddress('192.168.1.5')],
  'mixed.example': [
    InternetAddress('93.184.215.14'),
    InternetAddress('10.0.0.7'),
  ],
  'v6.example': [InternetAddress('fd12:3456::1')],
};

Future<List<InternetAddress>> resolve(String host) async => names[host] ?? [];

/// A web server that answers each URL from [pages], and keeps what was
/// asked for.
class FakeWeb {
  FakeWeb(this.pages);

  final Map<String, PageReply> pages;
  final asked = <(Uri, InternetAddress)>[];

  Future<PageReply> get(Uri url, InternetAddress address) async {
    asked.add((url, address));
    return pages['$url'] ?? const PageReply(404);
  }

  Future<String> fetch(String url) =>
      fetchWebPage(url, resolve: resolve, get: get);
}

/// The real [HttpClient], not flutter_test's.
class RealHttp extends HttpOverrides {}

PageReply html(String body) => PageReply(200,
    contentType: 'text/html; charset=utf-8', body: utf8.encode(body));

const mistral = ProviderConfig(
  name: 'Mistral',
  api: ApiKind.openAi,
  baseUrl: 'https://api.mistral.ai/v1',
  model: 'mistral-large-4',
  apiKey: 'm-test',
);

const bedrock = ProviderConfig(
  name: 'Claude on AWS Bedrock (EU)',
  api: ApiKind.anthropic,
  baseUrl: 'https://bedrock-runtime.eu-central-1.amazonaws.com/anthropic',
  model: 'claude-sonnet-5-5',
  apiKey: 'b-test',
);

List<String> toolNames(Map body) => [
      for (final tool in body['tools'] as List)
        (tool['name'] ?? tool['function']['name']) as String,
    ];

void main() {
  group('own network', () {
    bool own(String address) => isOwnNetwork(InternetAddress(address));

    test('loopback, private and link-local addresses are own', () {
      for (final address in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.0.10',
        '169.254.169.254',
        '100.64.0.1',
        '0.0.0.0',
        '::1',
        '::',
        'fc00::1',
        'fd12:3456::1',
        'fe80::1',
        '::ffff:192.168.1.1',
        '::ffff:127.0.0.1',
      ]) {
        expect(own(address), isTrue, reason: address);
      }
    });

    test('addresses on the internet are not', () {
      for (final address in [
        '93.184.215.14',
        '172.32.0.1',
        '8.8.8.8',
        '2606:4700::1111',
        '::ffff:93.184.215.14',
      ]) {
        expect(own(address), isFalse, reason: address);
      }
    });
  });

  group('fetch_web_page', () {
    test('gives the readable text of a page, without scripts and styles',
        () async {
      final web = FakeWeb({
        'https://example.org/report': html('''
<!doctype html><html><head><title>Rain &amp; sun</title>
<style>body { color: red }</style><script>alert("x")</script></head>
<body><h1>Rain in 2025</h1><p>It rained <b>40&nbsp;days</b>.</p>
<!-- a comment --><ul><li>Spring</li><li>Autumn</li></ul></body></html>'''),
      });
      final text = await web.fetch('https://example.org/report');
      expect(
          text,
          'Page https://example.org/report:\n\n'
          'Title: Rain & sun\nRain in 2025\nIt rained 40 days.\n'
          'Spring\nAutumn');
      // The connection goes to the address that was checked.
      expect(web.asked.single.$2, InternetAddress('93.184.215.14'));
    });

    test('plain text stays as it is; other types are not read', () async {
      final web = FakeWeb({
        'https://example.org/a.txt': PageReply(200,
            contentType: 'text/plain', body: utf8.encode('  <b>raw</b>\n')),
        'https://example.org/a.pdf':
            const PageReply(200, contentType: 'application/pdf'),
      });
      expect(await web.fetch('https://example.org/a.txt'),
          'Page https://example.org/a.txt:\n\n<b>raw</b>');
      await expectLater(web.fetch('https://example.org/a.pdf'),
          throwsA(isA<WebPageError>()));
    });

    test('only https: http and others are refused, nothing is fetched',
        () async {
      final web = FakeWeb({});
      for (final url in [
        'http://example.org/',
        'ftp://example.org/',
        'file:///etc/hosts',
        'example.org',
      ]) {
        await expectLater(
            web.fetch(url), throwsA(isA<WebPageError>()), reason: url);
      }
      expect(web.asked, isEmpty);
    });

    test('addresses in the own network are refused', () async {
      final web = FakeWeb({});
      for (final url in [
        'https://127.0.0.1/',
        'https://localhost/',
        'https://router.localhost/',
        'https://192.168.1.1/admin',
        'https://[::1]/',
        'https://[fe80::1]/',
        'https://169.254.169.254/latest/meta-data',
      ]) {
        await expectLater(
            web.fetch(url),
            throwsA(isA<WebPageError>().having(
                (e) => e.message, 'message', contains('phone itself'))),
            reason: url);
      }
      expect(web.asked, isEmpty);
    });

    test('a name that stands for an address in the own network is refused',
        () async {
      final web = FakeWeb({});
      for (final url in [
        'https://inside.example/',
        'https://mixed.example/',
        'https://v6.example/',
      ]) {
        await expectLater(
            web.fetch(url),
            throwsA(isA<WebPageError>().having(
                (e) => e.message, 'message', contains('own network'))),
            reason: url);
      }
      await expectLater(
          web.fetch('https://unknown.example/'), throwsA(isA<WebPageError>()));
      expect(web.asked, isEmpty);
    });

    test('a redirect is checked as the first address', () async {
      final web = FakeWeb({
        'https://example.org/in': const PageReply(302,
            location: 'https://inside.example/admin'),
        'https://example.org/plain':
            const PageReply(301, location: 'http://example.org/page'),
        'https://example.org/local':
            const PageReply(307, location: 'https://127.0.0.1:8080/'),
        'https://example.org/old': const PageReply(301, location: '/new'),
        'https://example.org/new': html('<p>New page</p>'),
      });
      await expectLater(web.fetch('https://example.org/in'),
          throwsA(isA<WebPageError>()));
      await expectLater(web.fetch('https://example.org/plain'),
          throwsA(isA<WebPageError>()));
      await expectLater(web.fetch('https://example.org/local'),
          throwsA(isA<WebPageError>()));
      // None of the redirects' targets was asked for.
      expect([for (final (url, _) in web.asked) '$url'], [
        'https://example.org/in',
        'https://example.org/plain',
        'https://example.org/local',
      ]);
      expect(await web.fetch('https://example.org/old'),
          'Page https://example.org/new:\n\nNew page');
    });

    test('too many redirects stop', () async {
      final web = FakeWeb({
        'https://example.org/loop':
            const PageReply(302, location: 'https://example.org/loop'),
      });
      await expectLater(web.fetch('https://example.org/loop'),
          throwsA(isA<WebPageError>()));
      expect(web.asked, hasLength(maxRedirects + 1));
    });

    test('a long page is cut, and the text says so', () async {
      final web = FakeWeb({
        'https://example.org/long': PageReply(200,
            contentType: 'text/plain',
            body: utf8.encode('word ' * 40000)),
      });
      final text = await web.fetch('https://example.org/long');
      expect(text, contains('The page was cut here'));
      expect(text.length, lessThan(maxPageText + 200));
    });

    test('an error status is an error', () async {
      final web = FakeWeb({});
      await expectLater(
          web.fetch('https://example.org/gone'),
          throwsA(isA<WebPageError>()
              .having((e) => e.message, 'message', contains('404'))));
    });
  });

  group('the connection', () {
    test('a body that never ends is cut off at the limit, and closed',
        () async {
      // A server that sends the headers, then a little of the body,
      // forever.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final closed = <Future<void>>[];
      Timer? drip;
      addTearDown(() => drip?.cancel());
      server.listen((socket) {
        final done = Completer<void>();
        closed.add(done.future);
        socket.listen((_) {
          socket.write('HTTP/1.1 200 OK\r\n'
              'Content-Type: text/plain\r\n'
              'Transfer-Encoding: chunked\r\n\r\n');
          drip = Timer.periodic(const Duration(milliseconds: 20), (_) {
            try {
              socket.write('5\r\nhello\r\n');
            } on Object {
              // The client is gone.
            }
          });
        }, onDone: () {
          drip?.cancel();
          if (!done.isCompleted) done.complete();
          socket.destroy();
        }, onError: (_) {
          drip?.cancel();
          if (!done.isCompleted) done.complete();
        });
      });
      final watch = Stopwatch()..start();
      // flutter_test replaces HttpClient with one that answers 400.
      await HttpOverrides.runWithHttpOverrides(
        () => expectLater(
          getWithPinnedAddress(
            Uri.parse('https://example.org:${server.port}/slow'),
            InternetAddress.loopbackIPv4,
            limit: const Duration(milliseconds: 300),
            connect: (address, url, limit) =>
                Socket.connect(address, url.port),
          ),
          throwsA(isA<TimeoutException>()),
        ),
        RealHttp(),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      // The server sees the connection closed: nothing reads on.
      expect(closed, hasLength(1));
      await closed.single.timeout(const Duration(seconds: 5));
    });
  });

  group('the chat with web access', () {
    final graph = graphOf(notes);
    RoamTools tools() => RoamTools(graph,
        readNote: (path) async => notes[path],
        visibility: const AiVisibility({'private'}));

    test('off: no web tool, no sentence on sources', () async {
      for (final config in [anthropic, mistral]) {
        final server = FakeServer([
          config == anthropic
              ? anthropicReply([
                  {'type': 'text', 'text': 'Hello.'},
                ])
              : openAiReply({'role': 'assistant', 'content': 'Hello.'}),
        ]);
        final session =
            ChatSession(tools: tools(), config: config, post: server.post);
        await session.send('Hi');
        final body = server.requests.single.body;
        expect(toolNames(body), [for (final tool in aiTools) tool.name]);
        expect(jsonEncode(body), isNot(contains('web_search')));
        expect(jsonEncode(body), isNot(contains('Name the sources')));
      }
    });

    test("Anthropic: fetch_web_page and the web_search server tool",
        () async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'Hello.'},
        ]),
      ]);
      final session = ChatSession(
          tools: tools(),
          config: anthropic,
          post: server.post,
          web: const WebAccess(limit: 5, search: true));
      await session.send('Hi');
      final body = server.requests.single.body;
      final offered = body['tools'] as List;
      expect(toolNames(body), [
        for (final tool in aiTools) tool.name,
        'fetch_web_page',
        'web_search',
      ]);
      expect(offered[aiTools.length]['input_schema']['required'], ['url']);
      expect(offered.last, {
        'type': 'web_search_20250305',
        'name': 'web_search',
        'max_uses': 5,
      });
      final system = body['system'][0]['text'] as String;
      expect(system, startsWith(systemPrompt));
      expect(system, contains('web_search'));
      expect(system, contains('Name the sources'));
      expect(system, contains('[[<URL>][<title>]]'));
    });

    test('Mistral and Bedrock: only fetch_web_page', () async {
      final server = FakeServer([
        openAiReply({'role': 'assistant', 'content': 'Hello.'}),
        anthropicReply([
          {'type': 'text', 'text': 'Hello.'},
        ]),
      ]);
      for (final config in [mistral, bedrock]) {
        final session = ChatSession(
            tools: tools(),
            config: config,
            post: server.post,
            web: WebAccess(limit: 5, search: hasWebSearch(config)));
        await session.send('Hi');
      }
      for (final request in server.requests) {
        final body = request.body;
        expect(toolNames(body),
            [for (final tool in aiTools) tool.name, 'fetch_web_page']);
        expect(jsonEncode(body), isNot(contains('web_search_2')));
        expect(jsonEncode(body), contains('Name the sources'));
      }
      expect(server.requests.first.body['tools'].last, {
        'type': 'function',
        'function': {
          'name': 'fetch_web_page',
          'description': fetchWebPageTool.description,
          'parameters': fetchWebPageTool.parameters,
        },
      });
    });

    test('the provider has web search only on Anthropic\'s own API', () {
      expect(hasWebSearch(anthropic), isTrue);
      expect(hasWebSearch(bedrock), isFalse);
      expect(hasWebSearch(mistral), isFalse);
    });

    test('fetch_web_page stops at the limit for one message', () async {
      Map<String, Object?> fetch(String id) => {
            'id': id,
            'type': 'function',
            'function': {
              'name': 'fetch_web_page',
              'arguments': jsonEncode({'url': 'https://example.org/$id'}),
            },
          };
      final server = FakeServer([
        openAiReply({
          'role': 'assistant',
          'content': null,
          'tool_calls': [fetch('a'), fetch('b'), fetch('c')],
        }, finish: 'tool_calls'),
        openAiReply({'role': 'assistant', 'content': 'Done.'}),
        openAiReply({
          'role': 'assistant',
          'content': null,
          'tool_calls': [fetch('d')],
        }, finish: 'tool_calls'),
        openAiReply({'role': 'assistant', 'content': 'Done.'}),
      ]);
      final fetched = <String>[];
      final session = ChatSession(
          tools: tools(),
          config: mistral,
          post: server.post,
          web: WebAccess(
              limit: 2,
              fetch: (url) async {
                fetched.add(url);
                return 'Page $url';
              }));
      await session.send('Read three pages');
      expect(fetched, ['https://example.org/a', 'https://example.org/b']);
      final results = [
        for (final m in server.requests[1].body['messages'] as List)
          if (m['role'] == 'tool') m['content'] as String,
      ];
      expect(results[0], 'Page https://example.org/a');
      expect(results[2], contains('limit of 2 web searches'));
      // The next message has the limit again.
      await session.send('One more');
      expect(fetched.last, 'https://example.org/d');
    });

    test("Anthropic's searches count, and its sources are shown", () async {
      final server = FakeServer([
        {
          ...anthropicReply([
            {
              'type': 'server_tool_use',
              'id': 'srvtoolu_1',
              'name': 'web_search',
              'input': {'query': 'rain 2025'},
            },
            {
              'type': 'web_search_tool_result',
              'tool_use_id': 'srvtoolu_1',
              'content': [
                {
                  'type': 'web_search_result',
                  'url': 'https://example.org/report',
                  'title': 'Rain report',
                  'encrypted_content': 'opaque',
                },
              ],
            },
            {
              'type': 'tool_use',
              'id': 'toolu_2',
              'name': 'fetch_web_page',
              'input': {'url': 'https://example.org/report'},
            },
          ], stop: 'tool_use'),
          'usage': {
            'input_tokens': 100,
            'output_tokens': 20,
            'server_tool_use': {'web_search_requests': 2},
          },
        },
        anthropicReply([
          {
            'type': 'text',
            'text': 'It rained 40 days.',
            'citations': [
              {
                'type': 'web_search_result_location',
                'url': 'https://example.org/report',
                'title': 'Rain [2025] report',
                'encrypted_index': 'opaque',
                'cited_text': 'It rained 40 days.',
              },
            ],
          },
        ]),
      ]);
      final session = ChatSession(
          tools: tools(),
          config: anthropic,
          post: server.post,
          web: WebAccess(
              limit: 5, search: true, fetch: (url) async => 'Page $url'));
      await session.send('How much rain in 2025?');
      expect(session.webLeft, 2);
      final second = server.requests.last.body;
      expect((second['tools'] as List).last['max_uses'], 2);
      // The search goes back unchanged, its encrypted content included.
      expect(jsonEncode(second['messages'][1]['content']),
          contains('"encrypted_content":"opaque"'));
      final first = session.transcript[1] as AssistantMessage;
      expect(first.searches.single.call.input, {'query': 'rain 2025'});
      expect(first.searches.single.content,
          'Rain report\n  https://example.org/report');
      final answer = session.transcript.last as AssistantMessage;
      expect(
          answer.text,
          'It rained 40 days.\n\nSources:\n'
          '- [[https://example.org/report][Rain 2025 report]]');
    });

    test('no searches left: web_search is no longer offered', () async {
      final server = FakeServer([
        {
          ...anthropicReply([
            {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'fetch_web_page',
              'input': {'url': 'https://example.org/a'},
            },
          ], stop: 'tool_use'),
          'usage': {
            'input_tokens': 1,
            'output_tokens': 1,
            'server_tool_use': {'web_search_requests': 1},
          },
        },
        anthropicReply([
          {'type': 'text', 'text': 'Done.'},
        ]),
      ]);
      final session = ChatSession(
          tools: tools(),
          config: anthropic,
          post: server.post,
          web: WebAccess(
              limit: 2, search: true, fetch: (url) async => 'Page $url'));
      await session.send('Search');
      expect(toolNames(server.requests.last.body), isNot(contains('web_search')));
      expect(toolNames(server.requests.last.body), contains('fetch_web_page'));
    });

    test('a paused turn is sent back as it is, and goes on', () async {
      final paused = [
        {
          'type': 'server_tool_use',
          'id': 'srvtoolu_1',
          'name': 'web_search',
          'input': {'query': 'rain'},
        },
      ];
      final server = FakeServer([
        anthropicReply(paused, stop: 'pause_turn'),
        anthropicReply([
          {'type': 'text', 'text': 'Done.'},
        ]),
      ]);
      final session = ChatSession(
          tools: tools(),
          config: anthropic,
          post: server.post,
          web: const WebAccess(limit: 5, search: true));
      await session.send('Search');
      expect(server.requests, hasLength(2));
      final messages = server.requests.last.body['messages'] as List;
      expect(messages, hasLength(2));
      expect(messages.last, {'role': 'assistant', 'content': paused});
      expect((session.transcript.last as AssistantMessage).text, 'Done.');
      expect(session.waiting, isFalse);
    });
  });

  group('settings', () {
    test('off by default, with 5 web searches for one message', () {
      const settings = AiSettings();
      expect(settings.webAccess, isFalse);
      expect(settings.maxWebSearches, 5);
      expect(AiSettings.fromJson({}).webAccess, isFalse);
    });

    test('saved and read back; a bad limit keeps the default', () {
      final saved = jsonDecode(jsonEncode(
          const AiSettings(webAccess: true, maxWebSearches: 3).toJson()));
      expect(AiSettings.fromJson(saved).webAccess, isTrue);
      expect(AiSettings.fromJson(saved).maxWebSearches, 3);
      expect(AiSettings.fromJson({'maxWebSearches': 0}).maxWebSearches, 5);
      expect(AiSettings.fromJson({'webAccess': 'yes'}).webAccess, isFalse);
    });

    testWidgets('the settings page turns web access on, with its limit',
        (tester) async {
      final store = MemoryAiSettingsStore();
      await pumpIn(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => AiSettingsScreen.open(context),
            child: const Text('open'),
          ),
        ),
        store: store,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('web-access'));
      await scrollTo(tester, toggle);
      expect(find.textContaining('Search words go to the provider'),
          findsOneWidget);
      expect(find.textContaining('pages are fetched from this phone'),
          findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('max-web-searches')), '3');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.settings.webAccess, isTrue);
      expect(store.settings.maxWebSearches, 3);
    });
  });

  test('a TLS handshake that never finishes is cut off, and its socket closed',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = Completer<void>();
    // Accepts the connection and never answers the handshake.
    server.listen((socket) => socket.listen((_) {},
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        }));
    try {
      await expectLater(
          connectSecure(InternetAddress.loopbackIPv4,
              Uri.parse('https://example.test:${server.port}/'),
              const Duration(milliseconds: 300)),
          throwsA(isA<TimeoutException>()));
      await closed.future.timeout(const Duration(seconds: 5));
    } finally {
      await server.close();
    }
  });
}
