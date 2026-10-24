import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_models.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/ai/model_picker.dart';

// All lists here are synthetic. Real provider answers belong in the PR.
List<ModelInfo> read(List<Map<String, Object?>> entries) =>
    readModelList({'data': entries}, api: ApiKind.openAi);

Map<String, Object?> image(String id, Map<String, Object?> pricing) => {
  'id': id,
  'type': 'image',
  'pricing': pricing,
};

void main() {
  group('image prices from model lists', () {
    test('Vercel fixed prices accept decimal strings and numbers, including zero',
        () {
      final models = read([
        image('a/image', {'image': '0.027'}),
        image('b/image', {'image': 0.125}),
        image('c/image', {'image': 0}),
      ]);
      expect(models.map((m) => m.imagePrice), [0.027, 0.125, 0]);
      expect(models.every((m) => !m.imagePriceFrom), isTrue);
    });

    test('Vercel uses the minimum across base, size, quality and style prices',
        () {
      final models = read([
        image('a/image', {
          'image': '0.12',
          'image_dimension_quality_pricing': [
            {'size': 'wide', 'quality': 'high', 'cost': '0.18'},
            {'size': 'square', 'quality': 'low', 'cost': '0.027'},
            {'size': 'bad', 'cost': -1},
            'bad entry',
          ],
        }),
        image('b/image', {
          'image': '0.027',
          'image_dimension_quality_pricing': [
            {'style': 'vector', 'cost': '0.054'},
          ],
        }),
        {
          'id': 'c/chat',
          'type': 'language',
          'tags': ['image-generation'],
          'pricing': {
            'input': '0.000002',
            'output': '0.000009',
            'image_dimension_quality_pricing': [
              {'size': 'large', 'cost': '0.09'},
              {'size': 'small', 'cost': 0.0125},
            ],
          },
        },
      ]);
      expect(models.map((m) => m.imagePrice), [0.027, 0.027, 0.0125]);
      expect(models.every((m) => m.imagePriceFrom), isTrue);
      expect(models.last.chat, isTrue);
      expect(models.last.inputPrice, 2);
      expect(models.last.outputPrice, 9);
    });

    test('a default-only image price is fixed; operation charges are not images',
        () {
      final models = read([
        image('a/image', {
          'image_dimension_quality_pricing': [
            {'size': 'default', 'cost': '0.027'},
            {'operation': 'web-grounding', 'cost': '0.001'},
          ],
        }),
        image('b/image', {
          'input': '0.000002',
          'output': '0.000009',
          'image_dimension_quality_pricing': [
            {'operation': 'web-grounding', 'cost': '0.001'},
          ],
        }),
      ]);
      expect(models.first.imagePrice, 0.027);
      expect(models.first.imagePriceFrom, isFalse);
      expect(models.last.imagePrice, isNull);
      expect(models.last.outputPrice, 9);
    });

    test('OpenRouter uses output-image pricing, never input-image pricing', () {
      final models = read([
        {
          'id': 'a/chat',
          'architecture': {'output_modalities': ['text', 'image']},
          'pricing': {
            'prompt': '0.000002',
            'completion': '0.000009',
            'image': '0.001',
            'image_output': '0.027',
          },
        },
        {
          'id': 'b/chat',
          'architecture': {'output_modalities': ['text', 'image']},
          'pricing': {
            'prompt': '0.000002',
            'completion': '0.000009',
            'image': '0.001',
            'image_token': '0.000007',
          },
        },
        {
          'id': 'c/vision',
          'architecture': {'output_modalities': ['text']},
          'pricing': {'image': '0.001', 'image_output': '0.027'},
        },
      ]);
      expect(models.first.images, isTrue);
      expect(models.first.chat, isTrue);
      expect(models.first.imagePrice, 0.027);
      expect(models.first.imagePriceFrom, isFalse);
      expect(models[1].imagePrice, isNull);
      expect(models[1].inputPrice, 2);
      expect(models[1].outputPrice, 9);
      expect(models.last.imagePrice, isNull);
    });

    test('a list without prices gives no price', () {
      final models = read([
        {'id': 'a/image'},
        image('b/image', {}),
        {'id': 'c/image', 'pricing': 'bad map'},
      ]);
      for (final model in models) {
        expect(model.imagePrice, isNull);
        expect(model.imagePriceFrom, isFalse);
        expect(model.inputPrice, isNull);
        expect(model.outputPrice, isNull);
      }
    });

    test('bad, negative and non-finite values give no price', () {
      for (final value in <Object?>[
        null, 'not a price', '', -0.5, '-0.5', 'NaN', 'Infinity',
        double.nan, double.infinity, true, [], {},
      ]) {
        final models = read([
          image('a/image', {
            'image': value, 'input': value, 'output': value,
          }),
          {
            'id': 'b/chat',
            'architecture': {'output_modalities': ['text', 'image']},
            'pricing': {'image_output': value},
          },
          image('c/image', {
            'image_dimension_quality_pricing': [
              {'size': 'square', 'cost': value},
            ],
          }),
        ]);
        for (final model in models) {
          expect(model.imagePrice, isNull, reason: '$value');
          expect(model.imagePriceFrom, isFalse, reason: '$value');
          expect(model.inputPrice, isNull, reason: '$value');
          expect(model.outputPrice, isNull, reason: '$value');
        }
      }
      final overflow = read([image('a/image', {'output': '1e308'})]);
      expect(overflow.single.outputPrice, isNull);
    });
  });

  testWidgets('image rows show fixed, from, token or missing prices',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final models = read([
      image('a/image', {'image': '0.027'}),
      image('b/image', {
        'image_dimension_quality_pricing': [
          {'size': 'small', 'cost': '0.0125'},
          {'size': 'large', 'cost': '0.09'},
        ],
      }),
      {
        'id': 'c/chat',
        'architecture': {'output_modalities': ['text', 'image']},
        'pricing': {'prompt': '0.000002', 'completion': '0.000009'},
      },
      image('d/image', {}),
      {
        'id': 'e/chat',
        'architecture': {'output_modalities': ['text', 'image']},
        'pricing': {'image_output': '0.000007'},
      },
      image('f/image', {'image': 0}),
    ]);
    await tester.pumpWidget(MaterialApp(home: ModelPickerScreen(
      provider: 'Synthetic', images: true,
      load: ({bool refresh = false}) async => models,
    )));
    await tester.pumpAndSettle();
    expect(find.text('\$0.027 per image'), findsOneWidget);
    expect(find.text('from \$0.0125 per image'), findsOneWidget);
    expect(find.textContaining('\$2.0 in, \$9.0 out per million tokens'),
        findsOneWidget);
    expect(find.text("price not in the provider's list"), findsOneWidget);
    expect(find.textContaining('\$0.000007 per image'), findsOneWidget);
    expect(find.text('\$0.00 per image'), findsOneWidget);
    expect(find.textContaining('chat model with image output'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('price order groups units, breaks ties, and survives refresh/search',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final models = read([
      image('a/unknown', {}),
      image('b/tokens', {'input': '0.000001', 'output': '0.000009'}),
      image('c/image', {'image': '0.12'}),
      image('d/tokens', {'input': '0.000002', 'output': '0.000004'}),
      {...image('e/image', {'image': '0.027'}), 'regions': ['us']},
      image('f/image', {'image': '0.027'}),
      image('g/image', {'image': 0}),
    ]);
    var refreshed = false;
    await tester.pumpWidget(MaterialApp(home: ModelPickerScreen(
      provider: 'Synthetic', images: true, euOnly: true,
      load: ({bool refresh = false}) async {
        refreshed = refresh;
        return models;
      },
    )));
    await tester.pumpAndSettle();
    List<String> order() => [
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
        (tile.title! as Text).data!,
    ];
    expect(order(), models.map((m) => m.id).toList());
    await tester.tap(find.byKey(const ValueKey('model-order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Price (lowest first)').last);
    await tester.pumpAndSettle();
    expect(order(), [
      'g/image', 'e/image', 'f/image', 'c/image',
      'd/tokens', 'b/tokens', 'a/unknown',
    ]);
    // Sorting must not change the caller's cached list or EU restrictions.
    expect(models.first.id, 'a/unknown');
    expect(tester.widget<ListTile>(find.byKey(
        const ValueKey('model-e/image'))).enabled, isFalse);
    await tester.enterText(find.byKey(const ValueKey('model-search')), 'image');
    await tester.pumpAndSettle();
    expect(order(), ['g/image', 'e/image', 'f/image', 'c/image']);
    await tester.tap(find.byTooltip('Fetch again'));
    await tester.pumpAndSettle();
    expect(refreshed, isTrue);
    expect(order(), ['g/image', 'e/image', 'f/image', 'c/image']);
    await tester.enterText(find.byKey(const ValueKey('model-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model ID').last);
    await tester.pumpAndSettle();
    expect(order(), models.map((m) => m.id).toList());
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat rows keep token prices and have no image sort control',
      (tester) async {
    final models = read([
      {
        'id': 'a/chat',
        'type': 'language',
        'tags': ['tool-use', 'image-generation'],
        'pricing': {
          'input': '0.000002', 'output': '0.000009',
          'image_dimension_quality_pricing': [
            {'size': 'default', 'cost': '0.027'},
          ],
        },
      },
    ]);
    await tester.pumpWidget(MaterialApp(home: ModelPickerScreen(
      provider: 'Synthetic',
      load: ({bool refresh = false}) async => models,
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-order')), findsNothing);
    expect(find.text('\$2.0 in, \$9.0 out per million tokens'), findsOneWidget);
    expect(find.textContaining('per image'), findsNothing);
  });
}
