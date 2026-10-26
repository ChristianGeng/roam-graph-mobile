import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_images.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/platform/error_text.dart';

const mistral = ProviderConfig(
  name: 'Mistral',
  api: ApiKind.openAi,
  baseUrl: 'https://api.mistral.ai/v1',
  model: 'mistral-medium-latest',
  apiKey: 'test-key-0123456789',
);

/// The text the mock clipboard got.
List<String> mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

void main() {
  test('the copied text: message, context block, answer', () {
    const report = ErrorReport(
      'Mistral refused the request.',
      provider: 'Mistral',
      model: 'mistral-medium-latest',
      api: 'mistral',
      status: 422,
      answer: '{"detail":"bad"}',
    );
    expect(
        report.text(
            version: '0.2.1-dev.7',
            platform: 'android',
            now: DateTime.utc(2026, 10, 26, 8, 30, 15, 123)),
        'Mistral refused the request.\n'
        '\n'
        'App version: 0.2.1-dev.7\n'
        'Platform: android\n'
        'Provider: Mistral\n'
        'Model: mistral-medium-latest\n'
        'API: mistral\n'
        'HTTP status: 422\n'
        'Time (UTC): 2026-10-26T08:30:15Z\n'
        '\n'
        'Answer:\n'
        '{"detail":"bad"}');
  });

  test('without AI details, only the app, platform and time', () {
    final text = const ErrorReport('Could not read a.org.').text(
        version: 'dev', platform: 'linux', now: DateTime.utc(2026, 1, 2, 3));
    expect(
        text,
        'Could not read a.org.\n'
        '\n'
        'App version: dev\n'
        'Platform: linux\n'
        'Time (UTC): 2026-01-02T03:00:00Z');
  });

  test('keys and tokens are removed', () {
    const raw = 'Header Authorization: Bearer sk-abc123DEF456 sent. '
        '{"api_key": "secret-value", "model": "m"} x-key: abc123 '
        'url https://h.example/v1?key=AbCd1234&a=1 and sk-proj-xyz_789.';
    final clean = redactSecrets(raw);
    for (final leaked in [
      'sk-abc123DEF456',
      'secret-value',
      'abc123',
      'AbCd1234',
      'sk-proj-xyz_789',
    ]) {
      expect(clean, isNot(contains(leaked)), reason: clean);
    }
    expect(clean, contains('"model": "m"'));
    expect(clean, contains('Bearer [removed]'));
    expect(redactSecrets('The key is hunter2-hunter2', secrets: [
      'hunter2-hunter2'
    ]), 'The key is [removed]');
  });

  test('the raw answer is cut to 2000 characters, after the keys are removed',
      () {
    final long = '${'a' * 1990} Bearer sk-secret-token-1234567 ${'b' * 500}';
    final clean = cleanAnswer(long);
    expect(clean.length, lessThanOrEqualTo(2000));
    expect(clean, isNot(contains('sk-secret')));
    expect(clean, isNot(contains('token-1234567')));
    expect(cleanAnswer('x' * 5000).length, 2000);
  });

  test('an HTTP error carries the cleaned answer and where it went', () async {
    final body = jsonEncode({
      'error': {'message': 'Invalid request.'},
      'echo': {'authorization': 'Bearer ${mistral.apiKey}'},
      'api_key': 'sk-leaked-0123456789',
      'text': 'Key ${mistral.apiKey} was used',
    });
    await expectLater(
      postJson(mistral, Uri.parse('https://api.mistral.ai/v1/x'), const {},
          const {}, (url, headers, text) async => HttpReply(400, body)),
      throwsA(isA<AiError>()
          .having((e) => e.status, 'status', 400)
          .having((e) => e.answer, 'answer', contains('Invalid request.'))
          .having((e) => e.answer, 'answer',
              isNot(anyOf(contains('sk-leaked'), contains(mistral.apiKey))))
          .having((e) => e.report().text(), 'text', contains('Provider: Mistral'))
          .having((e) => e.report().text(), 'text',
              isNot(contains('sk-leaked')))),
    );
  });

  test('a long answer from the provider is cut to 2000 characters', () async {
    final error = await postJson(
        mistral,
        Uri.parse('https://api.mistral.ai/v1/x'),
        const {},
        const {},
        (url, headers, text) async => HttpReply(500, 'x' * 5000)).then<AiError?>(
        (_) => null, onError: (Object e) => e as AiError);
    expect(error?.answer?.length, 2000);
  });

  test('an image answer without an image is kept in the error', () async {
    const config = ImageConfig(mistral,
        api: ImageApi.images, imagesPath: '/images/generations');
    try {
      await makeImage(
          config,
          'a fox',
          post: (url, headers, body) async =>
              HttpReply(200, jsonEncode({'data': [], 'note': 'no image'})));
      fail('no error');
    } on AiError catch (e) {
      expect(e.answer, contains('"note":"no image"'));
    }
  });

  testWidgets('the copy icon puts the message and the context on the clipboard',
      (tester) async {
    final copied = mockClipboard(tester);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ErrorText(ErrorReport('The image failed.',
            provider: 'Mistral', status: 500, answer: 'Server error')),
      ),
    ));
    expect(find.text('The image failed.'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
    await tester.tap(find.byTooltip('Copy error'));
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    final text = copied.single;
    expect(text, startsWith('The image failed.\n\nApp version: '));
    expect(text, contains('\nPlatform: '));
    expect(text, contains('\nProvider: Mistral\n'));
    expect(text, contains('\nHTTP status: 500\n'));
    expect(text, matches(RegExp(r'Time \(UTC\): \d{4}-\d\d-\d\dT[\d:]+Z')));
    expect(text, endsWith('\n\nAnswer:\nServer error'));
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('an error snack bar has a Copy action', (tester) async {
    final copied = mockClipboard(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showErrorSnackBar(
                ScaffoldMessenger.of(context), 'Could not save: disk full'),
            child: const Text('Go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('Could not save: disk full'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied.single, startsWith('Could not save: disk full\n\n'));
    expect(copied.single, contains('App version: '));
  });
}
