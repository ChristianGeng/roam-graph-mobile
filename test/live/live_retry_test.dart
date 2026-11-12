import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';

import 'live_retry.dart';

/// The error `postJson` throws when a provider does not answer in time.
const timedOut = AiError('openrouter.ai did not answer in time. Try again.');

void main() {
  group('isTransient (#278)', () {
    test('a timeout and a passing error are transient', () {
      expect(isTransient(timedOut), isTrue);
      expect(
        isTransient(const AiError('No connection', passing: true)),
        isTrue,
      );
    });

    test('a refused request, a test failure and other errors are not', () {
      expect(isTransient(const AiError('The API key was refused.')), isFalse);
      expect(isTransient(TestFailure('the bytes are no image')), isFalse);
      expect(isTransient(StateError('bad')), isFalse);
    });
  });

  group('withOneRetry (#278)', () {
    test('a first success is returned without a retry', () async {
      var calls = 0;
      Object? retried;
      final result = await withOneRetry(
        () async {
          calls++;
          return 'png';
        },
        wait: Duration.zero,
        onRetry: (e) => retried = e,
      );
      expect(result, 'png');
      expect(calls, 1);
      expect(retried, isNull);
    });

    test('a timeout is retried once, and the second answer counts', () async {
      var calls = 0;
      Object? retried;
      final result = await withOneRetry(
        () async {
          calls++;
          if (calls == 1) throw timedOut;
          return 'png';
        },
        wait: Duration.zero,
        onRetry: (e) => retried = e,
      );
      expect(result, 'png');
      expect(calls, 2);
      expect(retried, same(timedOut));
    });

    test('a second transient failure is thrown', () async {
      var calls = 0;
      final second = const AiError('No connection', passing: true);
      await expectLater(
        withOneRetry(() async {
          calls++;
          throw calls == 1 ? timedOut : second;
        }, wait: Duration.zero),
        throwsA(same(second)),
      );
      expect(calls, 2);
    });

    test('an error that is not transient is thrown at once', () async {
      var calls = 0;
      const refused = AiError('The API key was refused.', status: 401);
      await expectLater(
        withOneRetry(() async {
          calls++;
          throw refused;
        }, wait: Duration.zero),
        throwsA(same(refused)),
      );
      expect(calls, 1);
    });

    test('a failed check of the image is not retried', () async {
      var calls = 0;
      await expectLater(
        withOneRetry<String>(() async {
          calls++;
          throw TestFailure('the image has 12 bytes');
        }, wait: Duration.zero),
        throwsA(isA<TestFailure>()),
      );
      expect(calls, 1);
    });
  });
}
