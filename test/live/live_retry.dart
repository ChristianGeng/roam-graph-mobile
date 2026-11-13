/// One retry for a live case (#278): a provider that does not answer in
/// time, or drops the connection, often answers the same request a moment
/// later, as a user's "Try again" would show. The live tests retry such a
/// case once, so a single hiccup at a provider does not open an issue;
/// a second failure does.
///
/// Not tagged `live`: it makes no network calls, so the normal test step
/// runs its tests (live_retry_test.dart).
library;

import 'package:roam_graph_mobile/ai/ai_chat.dart';

/// The texts of the app's errors for a timeout or a lost connection where
/// the error is not marked [AiError.passing]: a request that got no answer
/// in time (`postJson`, `fetchModels`), a broken connection while fetching
/// the model list (`fetchModels`), and a broken or too slow image download
/// (`downloadWithDartIo`). An image download that the server refuses
/// ("could not be downloaded (HTTP …)") is not among them. They are
/// compared without regard to case: Mistral's image code wraps a download
/// error as "Mistral made an image, but the image download …".
const transientTexts = [
  'did not answer in time',
  'No connection to ',
  'The connection to ',
  'The image download took too long',
  'The image could not be downloaded: ',
];

/// Whether [error] is one a user would answer with "Try again": the error
/// says it may well pass ([AiError.passing]: a broken connection or an
/// overloaded provider in a chat or image request), or its text is one of
/// [transientTexts].
bool isTransient(Object error) {
  if (error is! AiError) return false;
  if (error.passing) return true;
  final text = error.message.toLowerCase();
  return transientTexts.any((t) => text.contains(t.toLowerCase()));
}

/// Runs [body]; if it fails with a transient error ([isTransient]), calls
/// [onRetry] with that error, waits [wait] and runs [body] once more. Any
/// other error, and a second failure, is thrown as it is.
Future<T> withOneRetry<T>(
  Future<T> Function() body, {
  Duration wait = const Duration(seconds: 30),
  void Function(Object first)? onRetry,
}) async {
  try {
    return await body();
  } on Object catch (e) {
    if (!isTransient(e)) rethrow;
    onRetry?.call(e);
    await Future<void>.delayed(wait);
    return body();
  }
}
