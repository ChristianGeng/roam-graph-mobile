import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/installer_asset.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('installer_asset'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A Linux package with [installer] as bundle/install.sh (or without it),
  /// packed the way the linux job packs it: `tar -C … -czf … bundle`.
  String tarball(String? installer) {
    final bundle = Directory('${tmp.path}/build/bundle')
      ..createSync(recursive: true);
    File('${bundle.path}/VERSION').writeAsStringSync('Roam Graph 9.9.9\n');
    if (installer != null) {
      File('${bundle.path}/install.sh').writeAsStringSync(installer);
    }
    final path = '${tmp.path}/roam-graph-9.9.9-linux-x64.tar.gz';
    final result = Process.runSync(
        'tar', ['-C', '${tmp.path}/build', '-czf', path, 'bundle']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return path;
  }

  File source(String text) =>
      File('${tmp.path}/install.sh.source')..writeAsStringSync(text);

  const installer = '#!/bin/sh\necho "install Roam Graph"\n';

  test('the checksum line is what sha256sum prints', () {
    // SHA-256 of "abc", from FIPS 180-2.
    expect(
        checksumLine('abc'.codeUnits, 'install.sh'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        '  install.sh\n');
  });

  test('the installer from the package becomes the asset, with its checksum',
      () {
    final out = '${tmp.path}/out';
    final line = prepareInstallerAsset(
        tarball: tarball(installer),
        source: source(installer).path,
        outFolder: out);
    final asset = File('$out/install.sh');
    expect(asset.readAsStringSync(), installer);
    expect(File('$out/install.sh.sha256').readAsStringSync(), line);
    expect(line, checksumLine(installer.codeUnits, 'install.sh'));
  });

  test('sha256sum -c accepts the asset with its checksum file', () {
    final out = '${tmp.path}/out';
    prepareInstallerAsset(
        tarball: tarball(installer),
        source: source(installer).path,
        outFolder: out);
    final ok = Process.runSync('sha256sum', ['-c', 'install.sh.sha256'],
        workingDirectory: out);
    expect(ok.exitCode, 0, reason: '${ok.stdout}${ok.stderr}');

    // A changed asset fails the same check.
    File('$out/install.sh').writeAsStringSync('$installer# changed\n');
    final changed = Process.runSync('sha256sum', ['-c', 'install.sh.sha256'],
        workingDirectory: out);
    expect(changed.exitCode, isNot(0));
  },
      skip: _hasSha256sum() ? false : 'sha256sum is not installed');

  test('an installer in the package that differs from the source fails', () {
    final out = '${tmp.path}/out';
    expect(
        () => prepareInstallerAsset(
            tarball: tarball('$installer# not the reviewed one\n'),
            source: source(installer).path,
            outFolder: out),
        throwsA(isA<InstallerAssetException>().having(
            (e) => e.message, 'message', contains('not the same file'))));
    expect(Directory(out).existsSync(), isFalse,
        reason: 'nothing is written when the files differ');
  });

  test('a package without bundle/install.sh fails', () {
    expect(
        () => prepareInstallerAsset(
            tarball: tarball(null),
            source: source(installer).path,
            outFolder: '${tmp.path}/out'),
        throwsA(isA<InstallerAssetException>().having(
            (e) => e.message, 'message', contains('has no bundle/install.sh'))));
  });

  test('a missing source file fails', () {
    expect(
        () => prepareInstallerAsset(
            tarball: tarball(installer),
            source: '${tmp.path}/no-such-file',
            outFolder: '${tmp.path}/out'),
        throwsA(isA<InstallerAssetException>()));
  });
}

/// Whether GNU `sha256sum` is on the path: Linux has it, a stock macOS does
/// not (it has `shasum`).
bool _hasSha256sum() {
  try {
    return Process.runSync('sha256sum', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
