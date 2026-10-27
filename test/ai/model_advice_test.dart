import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_models.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/ai/model_advice.dart';
import 'package:roam_graph_mobile/ai/model_picker.dart';

/// Words in ~…~ on the help page that are no model IDs.
const notModels = {'create_chart'};

Set<String> helpModels() => {
      for (final m in RegExp(r'~([^~\s]+)~')
          .allMatches(File('assets/help/models.org').readAsStringSync()))
        m.group(1)!,
    }..removeAll(notModels);

List<ModelInfo> synthetic(List<Map<String, Object?>> entries, ApiKind api) =>
    readModelList({'data': entries}, api: api);

Future<void> openPicker(
  WidgetTester tester,
  List<ModelInfo> models, {
  String providerId = 'openrouter',
  bool images = false,
}) async {
  await tester.pumpWidget(const SizedBox());
  await tester.binding.setSurfaceSize(const Size(800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ModelPickerScreen(
      provider: 'Synthetic',
      providerId: providerId,
      images: images,
      load: ({bool refresh = false}) async => models,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('the advice list', () {
    test('has no duplicate entries and only known providers', () {
      final keys = [for (final a in modelAdvice) '${a.provider} ${a.model}'];
      expect(keys.toSet().length, keys.length);
      final ids = providerPresets.map((p) => p.id).toSet();
      for (final a in modelAdvice) {
        expect(ids, contains(a.provider));
        expect(a.purposes, isNotEmpty);
        expect(a.why, isNotEmpty);
        expect(a.model, isNotEmpty);
        // An entry is for the chat or for images, not for both.
        expect(a.purposes.every((p) => p.isImage) ||
            a.purposes.every((p) => !p.isImage), isTrue);
      }
    });

    test('every purpose has a model for Mistral, Vercel and OpenRouter', () {
      for (final provider in ['mistral', 'vercel', 'openrouter']) {
        final purposes = {
          for (final a in adviceForProvider(provider)) ...a.purposes,
        };
        // Mistral's image tool does not set text well: no infographic model.
        final wanted = provider == 'mistral'
            ? AdvicePurpose.values.where((p) => p != AdvicePurpose.infographic)
            : AdvicePurpose.values;
        for (final purpose in wanted) {
          expect(purposes, contains(purpose), reason: '$provider $purpose');
        }
      }
    });

    test('recommended chat and image models of a preset are found', () {
      expect(
          adviceForModel('vercel', 'openai/gpt-image-1-mini', images: true)
              ?.price,
          PriceClass.cheap);
      expect(adviceForModel('vercel', 'openai/gpt-image-1-mini', images: false),
          isNull);
      expect(adviceForModel('vercel', 'unknown/model', images: false), isNull);
      expect(adviceForModel('mistral', 'mistral-large-4', images: false)
          ?.purposeLabels, 'chat, agent');
    });

    test('the presets name recommended models', () {
      for (final preset in providerPresets) {
        for (final model in [preset.defaultModel, preset.strongModel]) {
          if (model.isEmpty) continue;
          expect(adviceForModel(preset.id, model, images: false), isNotNull,
              reason: '${preset.id} $model');
        }
        for (final model in [preset.imageModel, preset.euImageModel]) {
          if (model.isEmpty) continue;
          expect(adviceForModel(preset.id, model, images: true), isNotNull,
              reason: '${preset.id} $model');
        }
      }
    });
  });

  test('the OpenRouter preset has a default, a strong and an image model', () {
    final preset = presetById('openrouter');
    expect(preset.defaultModel, 'deepseek/deepseek-v4-pro');
    expect(preset.strongModel, 'anthropic/claude-sonnet-5.5');
    expect(preset.imageModel, 'google/gemini-2.5-flash-image');
    expect(preset.imageApi, ImageApi.images);
    expect(preset.imagesPath, '/images');
  });

  test('the help page and the advice list name the same models', () {
    final inHelp = helpModels();
    final inAdvice = {for (final a in modelAdvice) a.model};
    expect(inHelp.difference(inAdvice), isEmpty,
        reason: 'on the help page, not in model_advice.dart');
    expect(inAdvice.difference(inHelp), isEmpty,
        reason: 'in model_advice.dart, not on the help page');
  });

  group('the model picker', () {
    final chatModels = synthetic([
      {'id': 'a/plain', 'supported_parameters': ['tools'],
        'pricing': {'prompt': '0.000001', 'completion': '0.000009'}},
      {'id': 'deepseek/deepseek-v4-pro', 'supported_parameters': ['tools'],
        'pricing': {'prompt': '0.000001', 'completion': '0.000002'}},
      {'id': 'b/cheap', 'supported_parameters': ['tools'],
        'pricing': {'prompt': '0.0000001', 'completion': '0.0000003'}},
      {'id': 'c/no-tools', 'supported_parameters': ['temperature'],
        'pricing': {'prompt': '0.0000001', 'completion': '0.0000001'}},
    ], ApiKind.openAi);

    List<String> order(WidgetTester tester) => [
          // The model rows only, not the switch "Also other models".
          for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
            if (tile.key case ValueKey<String>(:final value)
                when value.startsWith('model-') && value != 'model-all')
              (tile.title! as Text).data!,
        ];

    testWidgets('marks a recommended model and lists it first',
        (tester) async {
      await openPicker(tester, chatModels);
      final badge = find.byKey(const ValueKey('badge-deepseek/deepseek-v4-pro'));
      expect(badge, findsOneWidget);
      expect(tester.widget<Text>(badge).data,
          startsWith('Recommended: chat, agent · cheap'));
      expect(find.byKey(const ValueKey('badge-a/plain')), findsNothing);
      expect(order(tester).first, 'deepseek/deepseek-v4-pro');
    });

    testWidgets('the "Recommended" chip keeps only those', (tester) async {
      await openPicker(tester, chatModels);
      expect(find.byKey(const ValueKey('model-a/plain')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model-recommended')));
      await tester.pumpAndSettle();
      expect(order(tester), ['deepseek/deepseek-v4-pro']);
      await tester.tap(find.byKey(const ValueKey('model-recommended')));
      await tester.pumpAndSettle();
      expect(order(tester), hasLength(3));
    });

    testWidgets('no chip and no badge without recommended models',
        (tester) async {
      await openPicker(tester, chatModels, providerId: 'mistral');
      expect(find.byKey(const ValueKey('model-recommended')), findsNothing);
      expect(find.textContaining('Recommended:'), findsNothing);
      await openPicker(tester, chatModels, providerId: '');
      expect(find.byKey(const ValueKey('model-recommended')), findsNothing);
    });

    testWidgets('OpenRouter: "Calls tools" also works with other models on',
        (tester) async {
      await openPicker(tester, chatModels);
      expect(find.byKey(const ValueKey('model-tools')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model-all')));
      await tester.pumpAndSettle();
      expect(order(tester), contains('c/no-tools'));
      await tester.tap(find.byKey(const ValueKey('model-tools')));
      await tester.pumpAndSettle();
      expect(order(tester), isNot(contains('c/no-tools')));
      expect(order(tester), hasLength(3));
    });

    testWidgets('OpenRouter: price order, recommended models stay first',
        (tester) async {
      await openPicker(tester, chatModels);
      expect(find.byKey(const ValueKey('model-order')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model-order')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Price (lowest first)').last);
      await tester.pumpAndSettle();
      expect(order(tester), ['deepseek/deepseek-v4-pro', 'b/cheap', 'a/plain']);
    });

    testWidgets('other providers have no tools chip and no chat price order',
        (tester) async {
      await openPicker(tester, chatModels, providerId: 'vercel');
      expect(find.byKey(const ValueKey('model-tools')), findsNothing);
      expect(find.byKey(const ValueKey('model-order')), findsNothing);
    });

    testWidgets('image models: badge, chip and order', (tester) async {
      final images = synthetic([
        {'id': 'x/other',
          'architecture': {'output_modalities': ['image', 'text']}},
        {'id': 'google/gemini-2.5-flash-image',
          'architecture': {'output_modalities': ['image', 'text']}},
      ], ApiKind.openAi);
      await openPicker(tester, images, images: true);
      expect(order(tester).first, 'google/gemini-2.5-flash-image');
      final badge =
          find.byKey(const ValueKey('badge-google/gemini-2.5-flash-image'));
      expect(tester.widget<Text>(badge).data,
          startsWith('Recommended: illustration, infographic · medium'));
      expect(find.byKey(const ValueKey('model-order')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-tools')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('model-recommended')));
      await tester.pumpAndSettle();
      expect(order(tester), ['google/gemini-2.5-flash-image']);
    });
  });
}
