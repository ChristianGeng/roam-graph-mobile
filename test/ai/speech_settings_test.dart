import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';

import 'ai_settings_test.dart'
    show MemoryAiSettingsStore, MemoryKeyStore, backToAi, openRow, pumpIn, scrollTo;

Future<void> openAiPage(WidgetTester tester,
    {required MemoryAiSettingsStore store,
    required MemoryKeyStore keys}) async {
  await pumpIn(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => AiSettingsScreen.open(context),
        child: const Text('open'),
      ),
    ),
    store: store,
    keys: keys,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('AI settings: Speech to text (#221)', () {
    testWidgets('the row says which provider is used', (tester) async {
      await openAiPage(tester,
          store: MemoryAiSettingsStore(), keys: MemoryKeyStore());
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('ai-speech')),
              matching: find.text('Mistral (automatic)')),
          findsOneWidget);
    });

    testWidgets('choices are saved with the check mark and the OpenAI key '
        'goes to the key store', (tester) async {
      final store = MemoryAiSettingsStore();
      final keys = MemoryKeyStore();
      await openAiPage(tester, store: store, keys: keys);
      await openRow(tester, 'speech');
      for (final key in [
        'speech-model-mistral',
        'speech-model-openai',
        'speech-key-openai',
        'speech-speakers',
      ]) {
        await scrollTo(tester, find.byKey(ValueKey(key)));
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      await tester.enterText(
          find.byKey(const ValueKey('speech-model-openai')), 'whisper-1');
      await tester.enterText(
          find.byKey(const ValueKey('speech-key-openai')), 'sk-speech-test');
      await tester.tap(find.byKey(const ValueKey('speech-speakers')));
      await tester.pump();
      await backToAi(tester);
      expect(find.byKey(const ValueKey('ai-unsaved')), findsOneWidget);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.settings.speechModels, {'openai': 'whisper-1'});
      expect(store.settings.speechSpeakers, isTrue);
      expect(store.settings.speechProvider, '');
      expect(store.settings.speechLanguage, '');
      expect(keys.keys['openai-speech'], 'sk-speech-test');
    });

    testWidgets('a language code is checked', (tester) async {
      final store = MemoryAiSettingsStore(const AiSettings(
        speechLanguage: 'fr',
      ));
      await openAiPage(tester, store: store, keys: MemoryKeyStore());
      await openRow(tester, 'speech');
      final field = find.byKey(const ValueKey('speech-language-code'));
      await scrollTo(tester, field);
      await tester.enterText(field, 'nonsense!');
      await backToAi(tester);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('must be a language code'), findsOneWidget);
      expect(store.saves, 0);
    });

    testWidgets('saved choices show again', (tester) async {
      final store = MemoryAiSettingsStore(const AiSettings(
        speechProvider: 'openai',
        speechLanguage: 'fr',
      ));
      await openAiPage(tester, store: store, keys: MemoryKeyStore());
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('ai-speech')),
              matching: find.text('OpenAI')),
          findsOneWidget);
      await openRow(tester, 'speech');
      await scrollTo(
          tester, find.byKey(const ValueKey('speech-language-code')));
      expect(find.widgetWithText(TextField, 'fr'), findsOneWidget);
    });
  });
}
