// Makes the Linux installer a release asset of its own (#249, decision 141),
// so the first install can be checked the same way an update is.
//
//   dart tool/installer_asset.dart TARBALL SOURCE OUT_FOLDER
//
// Takes bundle/install.sh out of the Linux package TARBALL, fails if it is
// not the same file as SOURCE (linux/packaging/install.sh), and writes
// OUT_FOLDER/install.sh and OUT_FOLDER/install.sh.sha256, the second in the
// format `sha256sum -c` reads. The linux job in .github/workflows/build.yml
// runs this after the build; the release job attaches both files.

import 'dart:io';

import 'package:crypto/crypto.dart';

/// The installer's path inside the Linux package.
const installerInTarball = 'bundle/install.sh';

/// The installer's name as a release asset; the README downloads it as
/// `releases/latest/download/install.sh`.
const installerAsset = 'install.sh';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
        'Usage: dart tool/installer_asset.dart TARBALL SOURCE OUT_FOLDER');
    exit(2);
  }
  try {
    final written = prepareInstallerAsset(
        tarball: args[0], source: args[1], outFolder: args[2]);
    stdout.write(written);
  } on InstallerAssetException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}

/// A reason why no installer asset is made.
class InstallerAssetException implements Exception {
  const InstallerAssetException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The bytes of [installerInTarball] in [tarball], read with `tar`.
List<int> installerFromTarball(String tarball) {
  final result = Process.runSync(
      'tar', ['-xzOf', tarball, installerInTarball],
      stdoutEncoding: null);
  if (result.exitCode != 0) {
    throw InstallerAssetException(
        '$tarball has no $installerInTarball: ${result.stderr}'.trim());
  }
  return result.stdout as List<int>;
}

/// The line `sha256sum -c` checks [name] with: the hex digest, two spaces,
/// the name.
String checksumLine(List<int> bytes, String name) =>
    '${sha256.convert(bytes)}  $name\n';

/// Writes the installer asset and its checksum file into [outFolder], after
/// checking that the installer in [tarball] is the same file as [source].
/// Returns the checksum line.
String prepareInstallerAsset(
    {required String tarball,
    required String source,
    required String outFolder}) {
  final packed = installerFromTarball(tarball);
  final sourceFile = File(source);
  if (!sourceFile.existsSync()) {
    throw InstallerAssetException('$source does not exist.');
  }
  final expected = sourceFile.readAsBytesSync();
  if (!_sameBytes(packed, expected)) {
    throw InstallerAssetException(
        '$installerInTarball in $tarball is not the same file as $source.');
  }
  final out = Directory(outFolder)..createSync(recursive: true);
  File('${out.path}/$installerAsset').writeAsBytesSync(packed);
  final line = checksumLine(packed, installerAsset);
  File('${out.path}/$installerAsset.sha256').writeAsStringSync(line);
  return line;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
