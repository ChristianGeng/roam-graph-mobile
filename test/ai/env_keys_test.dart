// API keys from environment variables on the desktop (#236).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';

import 'ai_settings_test.dart' show MemoryKeyStore, openRow, pumpIn, scrollTo;

EnvApiKeyStore storeWith(Map<String, String> env, [MemoryKeyStore? inner]) =>
    EnvApiKeyStore(inner: inner ?? MemoryKeyStore(), environment: env);

void main() {
  group('EnvApiKeyStore', () {
    test('a key only in the store', () async {
      final keys = storeWith({}, MemoryKeyStore()..keys['mistral'] = 'saved');
      expect(await keys.read('mistral'), 'saved');
      expect(keys.variable('mistral'), isNull);
    });

    test('a key only in a variable', () async {
      final keys = storeWith({'MISTRAL_API_KEY': ' from-env '});
      expect(await keys.read('mistral'), 'from-env');
      expect(keys.variable('mistral'), 'MISTRAL_API_KEY');
      expect(await keys.stored('mistral'), isEmpty);
    });

    test('in both, the saved key takes precedence', () async {
      final keys = storeWith({
        'OPENROUTER_API_KEY': 'from-env',
      }, MemoryKeyStore()..keys['openrouter'] = 'saved');
      expect(await keys.read('openrouter'), 'saved');
    });

    test('in neither', () async {
      expect(await storeWith({}).read('anthropic'), isNull);
    });

    test('Vercel: the repository name first, then Vercel\'s own', () async {
      expect(await storeWith({'AI_GATEWAY_API_KEY': 'b'}).read('vercel'), 'b');
      expect(
        await storeWith({
          'VERCEL_AI_GATEWAY_API_KEY': 'a',
          'AI_GATEWAY_API_KEY': 'b',
        }).read('vercel'),
        'a',
      );
    });

    test('a variable that is only whitespace is not set', () async {
      final keys = storeWith({
        'VERCEL_AI_GATEWAY_API_KEY': '  ',
        'AI_GATEWAY_API_KEY': 'b',
      });
      expect(keys.variable('vercel'), 'AI_GATEWAY_API_KEY');
      expect(await storeWith({'BRAVE_API_KEY': ' '}).read(braveKeyId), isNull);
    });

    test('Brave and OpenAI speech keys', () async {
      final keys = storeWith({
        'BRAVE_API_KEY': 'brave',
        'OPENAI_API_KEY': 'openai',
      });
      expect(await keys.read(braveKeyId), 'brave');
      expect(await keys.read('openai-speech'), 'openai');
      expect(await storeWith({'HF_TOKEN': 'hf'}).read('huggingface'), 'hf');
    });

    test('custom never reads a variable', () async {
      expect(keyVariables.containsKey('custom'), isFalse);
      expect(await storeWith({'OPENAI_API_KEY': 'x'}).read('custom'), isNull);
    });

    test('saving and removing go to the store only', () async {
      final inner = MemoryKeyStore();
      final keys = storeWith({'MISTRAL_API_KEY': 'from-env'}, inner);
      await keys.write('mistral', 'typed');
      expect(inner.keys['mistral'], 'typed');
      await keys.write('mistral', '');
      expect(inner.keys, isEmpty);
      expect(await keys.read('mistral'), 'from-env');
    });

    test('keyState: saved, from a variable, or neither', () async {
      final keys = storeWith({
        'MISTRAL_API_KEY': 'e',
        'DEEPSEEK_API_KEY': 'e',
      }, MemoryKeyStore()..keys['deepseek'] = 's');
      expect(await keyState(keys, 'mistral'), (
        saved: false,
        variable: 'MISTRAL_API_KEY',
      ));
      expect(await keyState(keys, 'deepseek'), (saved: true, variable: null));
      expect(await keyState(keys, 'qwen'), (saved: false, variable: null));
      expect(await keyState(MemoryKeyStore()..keys['qwen'] = 'k', 'qwen'), (
        saved: true,
        variable: null,
      ));
    });
  });

  group('per platform', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('the process environment is read on the desktop only', () {
      // Without a given environment the store reads the real one on the
      // desktop and none on Android; PATH is set in every test run.
      const real = EnvApiKeyStore(inner: _NoKeys());
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        final desktop =
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.windows ||
            platform == TargetPlatform.macOS;
        expect(real.readsEnvironment, desktop, reason: '$platform');
      }
    });

    test('the store each platform keeps keys in', () {
      const names = {
        TargetPlatform.android: "Android's secure storage",
        TargetPlatform.linux: 'the system keyring',
        TargetPlatform.macOS: 'the Keychain',
        TargetPlatform.windows: 'Credential Manager',
      };
      for (final MapEntry(key: platform, value: name) in names.entries) {
        debugDefaultTargetPlatformOverride = platform;
        expect(keyStoreName, name);
        expect(keyFieldHelp(null), 'Kept in $name, never in the notes.');
      }
    });
  });

  testWidgets('a key from a variable is shown as read from it, not saved', (
    tester,
  ) async {
    await pumpIn(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => AiSettingsScreen.open(context),
          child: const Text('open'),
        ),
      ),
      keys: storeWith({'ANTHROPIC_API_KEY': 'sk-env'}),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await openRow(tester, 'chat');
    final help = find.text(
      'Read from ANTHROPIC_API_KEY. A key typed here is saved in the app '
      'and takes precedence.',
      skipOffstage: false,
    );
    await scrollTo(tester, help);
    expect(help, findsOneWidget);
    expect(
      find.text('Remove the saved key', skipOffstage: false),
      findsNothing,
    );
    expect(find.text('sk-env'), findsNothing);
  });
}

/// A store with no keys, for the tests that only look at the environment.
class _NoKeys implements ApiKeyStore {
  const _NoKeys();

  @override
  Future<String?> read(String provider) async => null;

  @override
  Future<void> write(String provider, String key) async {}
}
