/// Old tool results sent as short stubs (#251): in a long agent chat most
/// of every request is notes, pages and graph output the model read many
/// messages ago. The requests carry a stub instead; the transcript the
/// user sees and the saved chat keep everything.
///
/// The shortening happens in steps, so the providers' prompt caches keep
/// working: between two steps every request starts with the same bytes as
/// the one before. Pure Dart, no Flutter.
library;

import 'ai_chat.dart';

/// How old tool results are shortened in requests.
class ToolResultShortening {
  const ToolResultShortening({
    this.enabled = true,
    this.afterTurns = defaultAfterTurns,
    this.minCharacters = defaultMinCharacters,
    this.stepCharacters = defaultStepCharacters,
  });

  /// "Shorten old tool results" off: every result is sent as it is.
  static const off = ToolResultShortening(enabled: false);

  static const defaultAfterTurns = 3;
  static const defaultMinCharacters = 2000;
  static const defaultStepCharacters = 50000;

  final bool enabled;

  /// A result is old once this many messages of mine came after it.
  final int afterTurns;

  /// Only results longer than this are shortened.
  final int minCharacters;

  /// A step shortens all old results at once, but only when the old, long
  /// results not yet shortened add up to this many characters. Until then
  /// the requests stay as they were, and their start stays in the cache.
  final int stepCharacters;
}

/// [transcript] as it is sent: tool results older than
/// [ToolResultShortening.afterTurns] of my messages and longer than
/// [ToolResultShortening.minCharacters] become a stub ([shortenedResult]),
/// without their image. My messages and the model's answers stay as they
/// are, and so do short and recent results. [transcript] is not changed.
///
/// Which results are stubs depends only on [transcript], so the same chat
/// gives the same requests after a restart. The steps are found by
/// replaying the chat: at each message of mine, the old results not yet
/// shortened count up, and once they reach
/// [ToolResultShortening.stepCharacters] all results old enough by then
/// are shortened together. Between two steps nothing changes, so the
/// requests of the messages between them only grow at the end.
List<ChatEntry> shortenOldToolResults(
    List<ChatEntry> transcript, ToolResultShortening shortening) {
  if (!shortening.enabled) return transcript;
  // The message of mine each entry belongs to: 0 before the first.
  final turnOf = <int>[];
  var turns = 0;
  for (final entry in transcript) {
    if (entry is UserMessage) turns++;
    turnOf.add(turns);
  }
  bool long(ToolResult result) =>
      result.content.length > shortening.minCharacters;
  // The long results' characters by the message they belong to.
  final longByTurn = List<int>.filled(turns + 1, 0);
  for (final (index, entry) in transcript.indexed) {
    if (entry is ToolResults) {
      for (final result in entry.results) {
        if (long(result)) longByTurn[turnOf[index]] += result.content.length;
      }
    }
  }
  // Replays the steps: [cutoff] is the last message whose results are
  // shortened; before the first step, none.
  var cutoff = 0;
  var pending = 0;
  for (var turn = 1; turn <= turns; turn++) {
    final oldest = turn - shortening.afterTurns;
    if (oldest <= cutoff) continue;
    pending = 0;
    for (var t = cutoff + 1; t <= oldest; t++) {
      pending += longByTurn[t];
    }
    if (pending >= shortening.stepCharacters) cutoff = oldest;
  }
  if (cutoff == 0) return transcript;
  return [
    for (final (index, entry) in transcript.indexed)
      if (entry is ToolResults && turnOf[index] <= cutoff)
        ToolResults([
          for (final result in entry.results)
            long(result)
                ? ToolResult(result.call, shortenedResult(result))
                : result,
        ])
      else
        entry,
  ];
}

/// The stub sent in place of [result]: the tool, what it was called with,
/// its length and its first line, so the model knows what it read and can
/// read it again.
String shortenedResult(ToolResult result) {
  final call = result.call;
  final argument = call.input.values.whereType<String>().firstOrNull;
  final what =
      argument == null ? call.name : '${call.name} "${_clip(argument, 60)}"';
  final first = result.content
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  final began = first.isEmpty ? '' : ' It began: "${_clip(first, 100)}".';
  final image = result.image == null ? '' : ' Its image is left out too.';
  return '[Earlier result of $what (${_grouped(result.content.length)} '
      'characters), shortened.$began$image Read it again if you need it.]';
}

String _clip(String text, int length) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= length ? one : '${one.substring(0, length)}…';
}

/// [n] with a comma between each three digits: 12,400.
String _grouped(int n) {
  final digits = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
