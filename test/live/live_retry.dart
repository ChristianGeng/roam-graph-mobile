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

/// Whether [error] is one a user would answer with "Try again": the
/// provider did not answer in time (`postJson` reports a timeout as not
/// passing, so it is matched by its text), or the error says it may well
/// pass ([AiError.passing]: a broken connection, an overloaded provider).
bool isTransient(Object error) =>
    error is AiError &&
    (error.passing || error.message.contains('did not answer in time'));

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
