import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/platform/follow_emacs.dart';

void main() {
  group('a message (#117)', () {
    test('with the token gives its ID', () {
      expect(idOf('{"token": "t0k", "id": "an-id"}', 't0k'), 'an-id');
      expect(idOf('{"id": " an-id ", "token": "t0k"}', 't0k'), 'an-id');
    });

    test('with a wrong or missing token is refused', () {
      expect(idOf('{"token": "wrong", "id": "an-id"}', 't0k'), isNull);
      expect(idOf('{"token": "t0", "id": "an-id"}', 't0k'), isNull);
      expect(idOf('{"id": "an-id"}', 't0k'), isNull);
      expect(idOf('{"token": 1, "id": "an-id"}', 't0k'), isNull);
    });

    test('that is malformed is ignored', () {
      for (final line in [
        '',
        'an-id',
        '{"token": "t0k"',
        '["t0k", "an-id"]',
        '{"token": "t0k"}',
        '{"token": "t0k", "id": 7}',
        '{"token": "t0k", "id": "  "}',
        '{"token": "t0k", "id": "a\\nb"}',
        '{"token": "t0k", "id": "${'x' * 257}"}',
      ]) {
        expect(idOf(line, 't0k'), isNull, reason: line);
      }
    });
  });

  group('the listener (#117)', () {
    late Directory folder;
    late FollowServer server;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('follow');
      server = await FollowServer.start(
        file: File('${folder.path}/sub/follow.json'),
        random: Random(1),
      );
    });

    tearDown(() async {
      await server.close();
      await folder.delete(recursive: true);
    });

    Future<void> send(String text) async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      socket.write(text);
      await socket.flush();
      await socket.close();
      await socket.drain<void>().catchError((Object _) {});
    }

    test('listens on 127.0.0.1 only', () {
      expect(server.address, InternetAddress.loopbackIPv4);
    });

    test('writes the port and the token, readable only by me', () async {
      final file = File('${folder.path}/sub/follow.json');
      final json = jsonDecode(await file.readAsString()) as Map;
      expect(json, {'port': server.port, 'token': server.token});
      expect(server.token.length, greaterThanOrEqualTo(32));
      if (!Platform.isWindows) {
        expect((await file.stat()).mode & 0x1ff, 0x180); // 0600
      }
      expect(
        file.parent
            .listSync()
            .map((e) => e.path)
            .where((p) => p.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('passes on IDs with the right token, and only those', () async {
      final ids = <String>[];
      final sub = server.ids.listen(ids.add);
      await send('{"token": "wrong", "id": "refused"}\n');
      await send('not json\n');
      await send('${jsonEncode({'token': server.token, 'id': 'node-1'})}\n');
      await send(jsonEncode({'token': server.token, 'id': 'node-2'}));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      expect(ids, ['node-1', 'node-2']);
    });

    test('ignores a message that is too long', () async {
      final ids = <String>[];
      final sub = server.ids.listen(ids.add);
      await send('{"token": "${server.token}", "id": "${'x' * 5000}"}\n');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      expect(ids, isEmpty);
    });

    test('closes a connection that takes too long', () async {
      final ids = <String>[];
      final sub = server.ids.listen(ids.add);
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final closed = socket.drain<void>().catchError((Object _) {});
      final watch = Stopwatch()..start();
      // A byte now and then, never a whole line.
      final drip = Timer.periodic(const Duration(milliseconds: 500), (_) {
        try {
          socket.add([0x7b]);
        } on Object {
          // Closed by the app.
        }
      });
      await closed.timeout(const Duration(seconds: 6));
      drip.cancel();
      socket.destroy();
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      await sub.cancel();
      expect(ids, isEmpty);
    });

    test('close removes the file', () async {
      final file = File('${folder.path}/sub/follow.json');
      await server.close();
      expect(file.existsSync(), isFalse);
      // tearDown closes again: that must not fail.
    });
  });

  group('the shipped Emacs file (#241)', () {
    test('is in emacs/ next to the executable on Linux and Windows', () {
      expect(
          followElispDir('/home/me/.local/share/roam-graph/app/roam-graph',
              macOS: false),
          '/home/me/.local/share/roam-graph/app/emacs');
      expect(
          followElispDir(r'C:\Programs\Roam Graph\roam_graph_mobile.exe',
              macOS: false),
          'C:/Programs/Roam Graph/emacs');
    });

    test('is in the app\'s Resources on macOS', () {
      expect(
          followElispDir(
              '/Applications/Roam Graph.app/Contents/MacOS/Roam Graph',
              macOS: true),
          '/Applications/Roam Graph.app/Contents/Resources/emacs');
    });

    test('the snippet loads it from that folder and turns following on', () {
      final snippet = followEmacsSnippet('/opt/rg "x"/emacs');
      expect(snippet, contains(r'(expand-file-name "/opt/rg \"x\"/emacs")'));
      expect(snippet, contains("(with-eval-after-load 'org-roam"));
      expect(snippet, contains("(require 'roam-graph-follow)"));
      expect(snippet, contains('(roam-graph-follow-mode 1)'));
      expect('('.allMatches(snippet).length, ')'.allMatches(snippet).length);
    });
  });
}
