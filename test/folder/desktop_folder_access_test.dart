import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/desktop_folder_access.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));
String hash(String text) => sha256.convert(utf8.encode(text)).toString();

void main() {
  late Directory dir;
  late DesktopFolderAccess access;
  final sep = Platform.pathSeparator;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('roam-desktop');
    Directory('${dir.path}${sep}roam${sep}sub').createSync(recursive: true);
    Directory('${dir.path}$sep.stversions').createSync();
    File('${dir.path}${sep}roam${sep}a.org').writeAsStringSync('A');
    File('${dir.path}${sep}roam${sep}sub${sep}b.org').writeAsStringSync('B');
    File('${dir.path}$sep.stversions${sep}old.org').writeAsStringSync('old');
    access = DesktopFolderAccess(
      statePath: '${dir.path}${sep}state.json',
      pick: () async => dir.path,
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('the folder is picked once and remembered (#116)', () async {
    expect(await access.savedFolder(), isNull);
    final picked = (await access.pickFolder())!;
    expect(picked.uri, dir.path);
    expect(picked.hasAccess, isTrue);
    expect(picked.canWrite, isTrue);
    final again = DesktopFolderAccess(statePath: '${dir.path}${sep}state.json');
    expect((await again.savedFolder())!.uri, dir.path);
  });

  test('lists files with paths from the folder, without Syncthing\'s',
      () async {
    final folder = (await access.pickFolder())!;
    final files = await access.listFiles(folder);
    final paths = {for (final f in files) f.path: f.isDirectory};
    expect(paths, {
      'state.json': false,
      'roam': true,
      'roam/a.org': false,
      'roam/sub': true,
      'roam/sub/b.org': false,
    });
    final a = files.firstWhere((f) => f.path == 'roam/a.org');
    expect(a.size, 1);
    expect(a.modified, greaterThan(0));
    expect(await access.readFiles([a]), [bytes('A')]);
  });

  test('a new file never replaces one; folders are made', () async {
    final roam = '${dir.path}${sep}roam';
    final made = await access.createFile(roam, 'new.org', bytes('N'));
    expect(File(made).readAsStringSync(), 'N');
    await expectLater(access.createFile(roam, 'a.org', bytes('X')),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'exists')));
    expect(File('$roam${sep}a.org').readAsStringSync(), 'A');
    final img = await access.createDirectory(roam, 'img');
    expect(Directory(img).existsSync(), isTrue);
    expect(await access.createDirectory(roam, 'img'), img);
    await expectLater(access.createDirectory(roam, 'a.org'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'not_a_dir')));
    // No temporary file is left.
    expect(Directory(roam).listSync().map((e) => e.path),
        isNot(contains(contains('.syncthing.'))));
  });

  test('symbolic links are followed, a loop ends', () async {
    if (Platform.isWindows) return;
    final elsewhere = Directory.systemTemp.createTempSync('roam-linked');
    addTearDown(() => elsewhere.deleteSync(recursive: true));
    File('${elsewhere.path}${sep}c.org').writeAsStringSync('C');
    Link('${dir.path}${sep}roam${sep}linked').createSync(elsewhere.path);
    Link('${dir.path}${sep}roam${sep}sub${sep}loop')
        .createSync('${dir.path}${sep}roam');
    final folder = (await access.pickFolder())!;
    final paths = {for (final f in await access.listFiles(folder)) f.path};
    expect(paths, contains('roam/linked/c.org'));
    expect(paths.where((p) => p.contains('loop/')), isEmpty);
  });

  test('the write check leaves a file of its name alone', () async {
    final folder = (await access.pickFolder())!;
    expect(folder.canWrite, isTrue);
    expect(Directory(dir.path).listSync().map((e) => e.path),
        isNot(contains(contains('write-test'))));
  });

  test('replace and delete only over the version read', () async {
    final roam = '${dir.path}${sep}roam';
    final a = '$roam${sep}a.org';
    await access.replaceFile(roam, 'a.org', a,
        expected: hash('A'), bytes: bytes('A2'));
    expect(File(a).readAsStringSync(), 'A2');
    await expectLater(
        access.replaceFile(roam, 'a.org', a,
            expected: hash('A'), bytes: bytes('A3')),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'changed')));
    expect(File(a).readAsStringSync(), 'A2');
    await expectLater(access.deleteFile(a, expected: hash('A')),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'changed')));
    await access.deleteFile(a, expected: hash('A2'));
    expect(File(a).existsSync(), isFalse);
    await expectLater(access.deleteFile(a, expected: hash('A2')),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'missing')));
  });
}
