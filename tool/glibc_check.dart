// Checks that the Linux app runs on Ubuntu 22.04: no file in the bundle may
// need a newer glibc or libstdc++ than 22.04 has (decision 123).
//
//   dart tool/glibc_check.dart BUNDLE_FOLDER
//
// Runs `objdump -T` on every ELF file under BUNDLE_FOLDER, prints the
// newest GLIBC_ and GLIBCXX_ version each one needs, and exits with 1 if
// any needs more than [maxGlibc] or [maxGlibcxx]. The linux job in
// .github/workflows/build.yml runs this after the build.

import 'dart:io';

/// Ubuntu 22.04's glibc.
const maxGlibc = [2, 35];

/// Ubuntu 22.04's libstdc++ (GCC 12).
const maxGlibcxx = [3, 4, 30];

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart tool/glibc_check.dart BUNDLE_FOLDER');
    exit(2);
  }
  final files = Directory(args[0])
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where(isElf)
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('No ELF files under ${args[0]}.');
    exit(1);
  }
  var failed = false;
  for (final file in files) {
    final result = Process.runSync('objdump', ['-T', file.path]);
    if (result.exitCode != 0) {
      stderr.writeln('objdump failed on ${file.path}: ${result.stderr}');
      exit(1);
    }
    final needs = neededVersions(result.stdout as String);
    final problems = tooNew(needs);
    stdout.writeln('${file.path}: '
        'GLIBC ${needs.glibc?.join('.') ?? '-'}, '
        'GLIBCXX ${needs.glibcxx?.join('.') ?? '-'}'
        '${problems.isEmpty ? '' : '  TOO NEW: ${problems.join(', ')}'}');
    if (problems.isNotEmpty) {
      failed = true;
      stdout.writeln('::error file=${file.path}::needs ${problems.join(', ')}; '
          'Ubuntu 22.04 has GLIBC ${maxGlibc.join('.')} and '
          'GLIBCXX ${maxGlibcxx.join('.')}');
    }
  }
  exit(failed ? 1 : 0);
}

/// Whether [file] starts with the ELF magic bytes.
bool isElf(File file) {
  final raf = file.openSync();
  try {
    final head = raf.readSync(4);
    return head.length == 4 &&
        head[0] == 0x7f &&
        head[1] == 0x45 &&
        head[2] == 0x4c &&
        head[3] == 0x46;
  } finally {
    raf.closeSync();
  }
}

/// The newest GLIBC_ and GLIBCXX_ versions in `objdump -T` output; null
/// for a library the file does not use. Only undefined symbols (`*UND*`)
/// are needs; a symbol the file defines itself, with its own version, is
/// not.
({List<int>? glibc, List<int>? glibcxx}) neededVersions(String objdump) {
  List<int>? glibc, glibcxx;
  final undefined =
      objdump.split('\n').where((line) => line.contains('*UND*')).join('\n');
  for (final match
      in RegExp(r'\b(GLIBC|GLIBCXX)_(\d+(?:\.\d+)*)\b').allMatches(undefined)) {
    final version = match.group(2)!.split('.').map(int.parse).toList();
    if (match.group(1) == 'GLIBC') {
      if (glibc == null || compare(version, glibc) > 0) glibc = version;
    } else {
      if (glibcxx == null || compare(version, glibcxx) > 0) glibcxx = version;
    }
  }
  return (glibc: glibc, glibcxx: glibcxx);
}

/// What in [needs] is newer than Ubuntu 22.04 has, for example
/// `GLIBC_2.38`; empty if nothing.
List<String> tooNew(({List<int>? glibc, List<int>? glibcxx}) needs) => [
      if (needs.glibc != null && compare(needs.glibc!, maxGlibc) > 0)
        'GLIBC_${needs.glibc!.join('.')}',
      if (needs.glibcxx != null && compare(needs.glibcxx!, maxGlibcxx) > 0)
        'GLIBCXX_${needs.glibcxx!.join('.')}',
    ];

/// Compares dotted versions part by part; a missing part counts as 0.
int compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
