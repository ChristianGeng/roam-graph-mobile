import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/platform/desktop.dart';

void main() {
  test('Emacs opens the file at the line, without waiting (#116)', () {
    expect(emacsArguments('/notes/roam/a.org', 12),
        ['-n', '-a', 'emacs', '+12', '/notes/roam/a.org']);
    expect(emacsArguments('/a.org', 0)[3], '+1');
  });

  test('the desktop is told by the target platform', () {
    expect(isDesktop, isFalse);
    expect(noteAppName, 'Orgro');
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(isDesktop, isTrue);
      expect(noteAppName, 'Emacs');
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(defaultEmacsClient, 'emacsclientw.exe');
    debugDefaultTargetPlatformOverride = null;
    expect(defaultEmacsClient, 'emacsclient');
  });

  test('links open with the desktop\'s opener', () async {
    final runs = <(String, List<String>)>[];
    Future<void> start(String exe, List<String> args) async =>
        runs.add((exe, args));
    final uri = Uri.parse('https://example.org/a?b=1&c=2');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await openUrlOnDesktop(uri, start: start), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await openUrlOnDesktop(uri, start: start);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await openUrlOnDesktop(uri, start: start);
    debugDefaultTargetPlatformOverride = null;
    expect(runs, [
      ('xdg-open', ['https://example.org/a?b=1&c=2']),
      ('open', ['https://example.org/a?b=1&c=2']),
      ('rundll32', ['url.dll,FileProtocolHandler', 'https://example.org/a?b=1&c=2']),
    ]);
  });
}
