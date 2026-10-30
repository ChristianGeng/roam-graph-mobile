import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/capture/share_inbox.dart';
import 'package:roam_graph_mobile/capture/share_out.dart';

OutFile file(String name, List<int> bytes) => OutFile(
    name: name, mimeType: 'image/png', bytes: Uint8List.fromList(bytes));

void main() {
  late Directory cache;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('share_out_test');
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  test('the copies are written in order, a repeated name gets its place',
      () async {
    final paths = await copyToShareCache(
      [file('a.png', [1, 2]), file('b.png', [3]), file('a.png', [4])],
      cache: cache,
      now: () => DateTime.utc(2026, 1, 2),
    );
    expect(paths, hasLength(3));
    expect([for (final path in paths) path.split('/').last],
        ['a.png', 'b.png', '2-a.png']);
    expect(File(paths[0]).readAsBytesSync(), [1, 2]);
    expect(File(paths[1]).readAsBytesSync(), [3]);
    expect(File(paths[2]).readAsBytesSync(), [4]);
    // All below the cache folder, in a folder of this share.
    for (final path in paths) {
      expect(path, startsWith(cache.path));
    }
  });

  test('the clean-up removes old share copies', () async {
    final old = await copyToShareCache([file('a.png', [1])],
        cache: cache, now: () => DateTime.utc(2020));
    final recent = await copyToShareCache([file('b.png', [2])],
        cache: cache, now: () => DateTime.utc(2026));
    expect(File(old.single).existsSync(), isTrue);

    await deleteShareCache(cache: cache);

    expect(File(old.single).existsSync(), isFalse);
    expect(File(recent.single).existsSync(), isFalse);
    expect(cache.existsSync(), isFalse);
    // Nothing there: no error.
    await deleteShareCache(cache: cache);
  });

  test('MIME types and file names', () {
    expect(mimeTypeOf('img/a.PNG'), 'image/png');
    expect(mimeTypeOf('a.jpeg'), 'image/jpeg');
    expect(mimeTypeOf('a.jpg'), 'image/jpeg');
    expect(mimeTypeOf('a.webp'), 'image/webp');
    expect(mimeTypeOf('a.svg'), 'image/svg+xml');
    expect(mimeTypeOf('a.org'), 'text/plain');
    expect(fileNameFor('Plan: a/b?'), 'Plan_ a_b_');
    expect(fileNameFor('  '), 'note');
    expect(fileNameFor('..'), 'note');
    expect(fileNameFor('x' * 100).length, 80);
  });

  test('on the desktop, shared text goes to the clipboard (#209)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    TestWidgetsFlutterBinding.ensureInitialized();
    final copied = <String?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String?);
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await shareTextOut('The note text', subject: 'Note');

    expect(copied, ['The note text']);
  });
}
