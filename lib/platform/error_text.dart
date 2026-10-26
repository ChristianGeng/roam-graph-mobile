/// Error messages that can be copied with one tap (#180), to paste into a
/// chat or an issue as they are: the message, then the app version, the
/// platform, what is known about the AI request, the time, and the
/// provider's own answer.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../main.dart' show appVersion;

/// The most characters of a provider's answer that are kept.
const maxAnswerLength = 2000;

/// [text] without anything that looks like a key or a token. [secrets] are
/// values, such as the API key in use, that are removed wherever they
/// appear.
String redactSecrets(String text, {Iterable<String> secrets = const []}) {
  var out = text;
  for (final secret in secrets) {
    if (secret.length >= 4) out = out.replaceAll(secret, '[removed]');
  }
  out = out.replaceAllMapped(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (_) => 'Bearer [removed]');
  // JSON: "api_key": "…", "token": "…", "authorization": "…"
  out = out.replaceAllMapped(
      RegExp(
          r'("(?:api[_-]?key|x-api-key|x-key|authorization|access[_-]?token|'
          r'token|secret|client[_-]?secret|password)"\s*:\s*)"[^"]*"',
          caseSensitive: false),
      (m) => '${m[1]}"[removed]"');
  // Headers and settings: x-key: …, x-api-key=…, authorization: …
  out = out.replaceAllMapped(
      RegExp(
          r'\b(x-api-key|x-key|api-key|authorization)(\s*[:=]\s*)'
          r'(?!Bearer \[removed\])(?:[A-Za-z]+\s+)?[^\s,;"' "'" r']+',
          caseSensitive: false),
      (m) => '${m[1]}${m[2]}[removed]');
  // Web addresses: ?key=…&…
  out = out.replaceAllMapped(
      RegExp(r'([?&](?:key|api_key|apikey|access_token|token)=)[^&\s"' "'" r']+',
          caseSensitive: false),
      (m) => '${m[1]}[removed]');
  // Keys of known shapes: sk-…, AIza…
  out = out.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]+'), '[removed]');
  out = out.replaceAll(RegExp(r'\bAIza[0-9A-Za-z_-]{20,}'), '[removed]');
  // Any other long run of letters and digits with both in it.
  out = out.replaceAllMapped(RegExp(r'[A-Za-z0-9_-]{40,}'), (m) {
    final run = m[0]!;
    return run.contains(RegExp(r'[0-9]')) && run.contains(RegExp(r'[A-Za-z]'))
        ? '[removed]'
        : run;
  });
  return out;
}

/// A provider's raw answer, ready to copy: keys and tokens removed first,
/// then cut to [maxAnswerLength] characters.
String cleanAnswer(String raw, {Iterable<String> secrets = const []}) {
  var out = redactSecrets(raw, secrets: secrets).trim();
  if (out.length > maxAnswerLength) {
    out = out.substring(0, maxAnswerLength);
    // Not in the middle of a character made of two code units.
    final last = out.codeUnitAt(out.length - 1);
    if (last >= 0xD800 && last <= 0xDBFF) {
      out = out.substring(0, out.length - 1);
    }
  }
  return out;
}

/// An error to show and to copy: the [message] as shown, and what helps to
/// find the cause when it is pasted elsewhere.
class ErrorReport {
  const ErrorReport(
    this.message, {
    this.provider,
    this.model,
    this.api,
    this.status,
    this.answer,
  });

  final String message;

  /// For AI errors: the provider's name, the model, the kind of API and the
  /// HTTP status, where they are known.
  final String? provider;
  final String? model;
  final String? api;
  final int? status;

  /// The provider's raw answer; cut and cleaned when it is copied.
  final String? answer;

  /// The same report with another [message].
  ErrorReport withMessage(String message) => ErrorReport(message,
      provider: provider,
      model: model,
      api: api,
      status: status,
      answer: answer);

  /// What is copied. [version], [platform] and [now] are for tests.
  String text({String? version, String? platform, DateTime? now}) {
    final time = (now ?? DateTime.now())
        .toUtc()
        .toIso8601String()
        .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
    final answer = this.answer?.trim();
    final lines = [
      redactSecrets(message),
      '',
      'App version: ${version ?? appVersion}',
      'Platform: ${platform ?? Platform.operatingSystem}',
      if (provider case final provider? when provider.isNotEmpty)
        'Provider: $provider',
      if (model case final model? when model.isNotEmpty) 'Model: $model',
      if (api case final api? when api.isNotEmpty) 'API: $api',
      if (status != null) 'HTTP status: $status',
      'Time (UTC): $time',
      if (answer != null && answer.isNotEmpty) ...[
        '',
        'Answer:',
        cleanAnswer(answer),
      ],
    ];
    return lines.join('\n');
  }
}

/// Puts [report] on the clipboard and says so.
Future<void> copyError(ScaffoldMessengerState messenger, ErrorReport report) =>
    _copy(messenger, report.text());

Future<void> _copy(ScaffoldMessengerState messenger, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!messenger.mounted) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('Copied')));
}

/// An error message in the error colour, which can be selected, with a
/// copy icon next to it.
class ErrorText extends StatelessWidget {
  const ErrorText(
    this.report, {
    super.key,
    this.textKey,
    this.copyKey,
    this.color,
  });

  /// A message without more to tell.
  ErrorText.message(String message,
      {Key? key, Key? textKey, Key? copyKey})
      : this(ErrorReport(message),
            key: key, textKey: textKey, copyKey: copyKey);

  final ErrorReport report;

  /// The key of the selectable message, for tests.
  final Key? textKey;

  /// The key of the copy icon.
  final Key? copyKey;

  /// The colour of text and icon; the theme's error colour by default.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SelectableText(
            report.message,
            key: textKey,
            style: TextStyle(color: color),
          ),
        ),
        IconButton(
          key: copyKey,
          tooltip: 'Copy error',
          visualDensity: VisualDensity.compact,
          onPressed: () => copyError(ScaffoldMessenger.of(context), report),
          icon: Icon(Icons.copy, size: 20, color: color),
        ),
      ],
    );
  }
}

/// Shows [message] as an error in a snack bar with a "Copy" action. A snack
/// bar with an action stays until it is dismissed, which suits an error.
void showErrorSnackBar(ScaffoldMessengerState messenger, String message,
    {ErrorReport? report}) {
  final copy = report ?? ErrorReport(message);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      action: SnackBarAction(
        label: 'Copy',
        onPressed: () => copyError(messenger, copy),
      ),
    ));
}

/// Shows [message] in a snack bar, replacing the one shown; an [error] gets
/// the "Copy" action of [showErrorSnackBar].
void showMessage(ScaffoldMessengerState messenger, String message,
    {bool error = false}) {
  if (error) {
    showErrorSnackBar(messenger, message);
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
