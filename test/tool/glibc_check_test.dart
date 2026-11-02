import 'package:flutter_test/flutter_test.dart';

import '../../tool/glibc_check.dart';

void main() {
  // Lines as `objdump -T` prints them; the versions are in parentheses.
  const objdump = '''
DYNAMIC SYMBOL TABLE:
0000000000000000      DF *UND*  0000000000000000 (GLIBC_2.2.5) free
0000000000000000      DF *UND*  0000000000000000 (GLIBC_2.38) __isoc23_strtol
0000000000000000      DF *UND*  0000000000000000 (GLIBC_2.14) memcpy
0000000000000000      DF *UND*  0000000000000000 (GLIBCXX_3.4.29) _ZSt28__throw
0000000000000000      DF *UND*  0000000000000000 (GLIBCXX_3.4) _ZdlPv
''';

  test('the newest GLIBC and GLIBCXX versions are found', () {
    final needs = neededVersions(objdump);
    expect(needs.glibc, [2, 38]);
    expect(needs.glibcxx, [3, 4, 29]);
  });

  test('a file that needs a glibc newer than Ubuntu 22.04 fails', () {
    // The case of the v0.2.0 bundle, built on Ubuntu 24.04: the sqlite3 and
    // flutter_secure_storage plugins needed GLIBC_2.38.
    expect(tooNew(neededVersions(objdump)), ['GLIBC_2.38']);
  });

  String und(String version) =>
      '0000000000000000      DF *UND*  0000000000000000 ($version) f\n';

  test('Ubuntu 22.04 versions pass, and a file without them too', () {
    expect(tooNew(neededVersions(und('GLIBC_2.35') + und('GLIBCXX_3.4.30'))),
        isEmpty);
    expect(tooNew(neededVersions(und('GLIBC_2.34'))), isEmpty);
    expect(neededVersions('no versions here').glibc, isNull);
    expect(tooNew(neededVersions('')), isEmpty);
  });

  test('a newer libstdc++ fails as well', () {
    expect(tooNew(neededVersions(und('GLIBCXX_3.4.32'))), ['GLIBCXX_3.4.32']);
  });

  test('a version the file defines itself is not a need', () {
    // A defined symbol (in .text, not *UND*) carries the file's own
    // version; only undefined symbols are taken from glibc or libstdc++.
    const defined = '00000000000a1b20 g    DF .text  0000000000000040 '
        '(GLIBCXX_3.4.33) _ZNSt6thread'
        '\n';
    expect(neededVersions(defined).glibcxx, isNull);
    expect(tooNew(neededVersions(defined + und('GLIBCXX_3.4.29'))), isEmpty);
  });

  test('versions compare by number, not as text', () {
    expect(compare([2, 9], [2, 10]), lessThan(0));
    expect(compare([3, 4], [3, 4, 0]), 0);
    expect(compare([2, 38], [2, 35]), greaterThan(0));
  });
}
