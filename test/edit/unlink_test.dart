import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/unlink.dart';

void main() {
  group('withoutIdLink', () {
    test('a link becomes its description, or its target without one', () {
      expect(withoutIdLink('See [[id:b][Bee]] now.\n', 'b', line: 1),
          'See Bee now.\n');
      expect(withoutIdLink('See [[id:b]] now.\n', 'b', line: 1),
          'See b now.\n');
      expect(withoutIdLink('x\n[[id:b::*H][H in B]]\n', 'b', line: 2),
          'x\nH in B\n');
    });

    test('only the link on that line, chosen by its position', () {
      const text = '[[id:b][one]]\n[[id:b][two]] [[id:b][three]]\n';
      expect(withoutIdLink(text, 'b', line: 2),
          '[[id:b][one]]\ntwo [[id:b][three]]\n');
      expect(withoutIdLink(text, 'b', line: 2, pos: 29),
          '[[id:b][one]]\n[[id:b][two]] three\n');
    });

    test('by its position alone, as the index gives it', () {
      const text = 'é [[id:b][one]]\n[[id:b][two]]\n';
      // "é" is one character for org-roam.
      expect(withoutIdLink(text, 'b', pos: 3), 'é one\n[[id:b][two]]\n');
      expect(withoutIdLink(text, 'b', pos: 17), 'é [[id:b][one]]\ntwo\n');
      // Moved since: the only link is still found; of two, none.
      expect(withoutIdLink('x [[id:b]]\n', 'b', pos: 1), 'x b\n');
      expect(() => withoutIdLink(text, 'b', pos: 5),
          throwsA(isA<UnlinkError>()));
    });

    test('a link no longer there is an error', () {
      expect(() => withoutIdLink('[[id:c]]\n', 'b', line: 1),
          throwsA(isA<UnlinkError>()));
      expect(() => withoutIdLink('x\n[[id:b]]\n', 'b', line: 1),
          throwsA(isA<UnlinkError>()));
    });
  });

  group('withoutImageLink', () {
    test('the link goes with its caption and prompt lines', () {
      const text = 'Before.\n'
          '# image prompt: a red fox\n'
          '#+caption: A fox\n'
          '#+attr_org: :width 300\n'
          '[[file:img/fox.png]]\n'
          'After.\n';
      expect(withoutImageLink(text, 'file:img/fox.png'), 'Before.\nAfter.\n');
    });

    test('at the end of a file without a newline', () {
      expect(withoutImageLink('A.\n#+caption: x\n[[file:p.png]]', 'file:p.png'),
          'A.\n');
    });

    test('a link inside a line goes alone', () {
      expect(withoutImageLink('#+caption: kept\nSee [[file:p.png]] here.\n',
              'file:p.png'),
          '#+caption: kept\nSee  here.\n');
    });

    test('a link twice, or not at all, is an error', () {
      expect(() => withoutImageLink('[[file:p.png]]\n[[file:p.png]]\n',
          'file:p.png'), throwsA(isA<UnlinkError>()));
      expect(() => withoutImageLink('text\n', 'file:p.png'),
          throwsA(isA<UnlinkError>()));
    });
  });
}
