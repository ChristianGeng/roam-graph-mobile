import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/capture/text_files.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';

/// The proposal as a list, since records with lists compare lists by
/// identity.
List<Object> proposal(TextFile file) {
  final (:title, :tags, :body) = proposeFromFile(file);
  return [title, tags, body];
}

IncomingFile utf8File(String name, String text, {String? mimeType}) =>
    IncomingFile(name,
        mimeType: mimeType, bytes: Uint8List.fromList(utf8.encode(text)));

void main() {
  group('readTextFiles (#220)', () {
    test('takes text files by name or MIME type', () {
      final read = readTextFiles([
        utf8File('notes.txt', 'Plain'),
        utf8File('readme.MD', 'Markdown'),
        utf8File('long.markdown', 'Long'),
        utf8File('tasks.org', 'Org', mimeType: 'application/octet-stream'),
        utf8File('content-1234', 'From a provider', mimeType: 'text/plain'),
        utf8File('picture.png', 'not text', mimeType: 'image/png'),
        utf8File('data.bin', 'binary', mimeType: 'application/octet-stream'),
      ]);
      expect([for (final f in read.files) f.name], [
        'notes.txt',
        'readme.MD',
        'long.markdown',
        'tasks.org',
        'content-1234',
      ]);
      expect([for (final r in read.refused) r.name],
          ['picture.png', 'data.bin']);
      expect(read.notes.single,
          startsWith('Not taken: picture.png (not a text file'));
    });

    test('refuses files over 1 MB and after the 20th', () {
      final big = Uint8List(maxFileBytes + 1);
      final read = readTextFiles([
        IncomingFile('big.txt', bytes: big),
        const IncomingFile('known-size.md', size: maxFileBytes + 10),
        IncomingFile('exactly.txt', bytes: Uint8List(maxFileBytes)),
        for (var i = 4; i <= 22; i++) utf8File('file$i.txt', 'Text $i'),
      ]);
      expect(read.files.length, 18);
      expect(read.files.first.name, 'exactly.txt');
      expect(read.refused, [
        (name: 'big.txt', reason: 'larger than 1 MB'),
        (name: 'known-size.md', reason: 'larger than 1 MB'),
        (name: 'file21.txt', reason: 'more than 20 files at once'),
        (name: 'file22.txt', reason: 'more than 20 files at once'),
      ]);
      expect(
          read.notes.single,
          'Not taken: big.txt (larger than 1 MB), known-size.md (larger '
          'than 1 MB), file21.txt (more than 20 files at once), file22.txt '
          '(more than 20 files at once).');
    });

    test('names files that could not be read', () {
      final read = readTextFiles(
          [const IncomingFile('gone.txt', error: 'No such file')]);
      expect(read.files, isEmpty);
      expect(read.refused.single.reason, 'could not be read: No such file');
    });

    test('reads a file that is not UTF-8 as Latin-1, with a note', () {
      final read = readTextFiles([
        IncomingFile('old.txt',
            bytes: Uint8List.fromList(latin1.encode('Caf\u00e9 cr\u00e8me'))),
        utf8File('new.txt', 'Caf\u00e9'),
      ]);
      expect(read.files[0].text, 'Caf\u00e9 cr\u00e8me');
      expect(read.files[0].latin1, isTrue);
      expect(read.files[1].latin1, isFalse);
      expect(read.notes, ['old.txt is not UTF-8; it was read as Latin-1.']);
    });

    test('keeps only the file name of a path', () {
      final read = readTextFiles([utf8File('/home/user/a/notes.txt', 'x')]);
      expect(read.files.single.name, 'notes.txt');
      expect(read.files.single.baseName, 'notes');
    });
  });

  group('proposeFromFile (#220)', () {
    test('without a title line, the file name is the title', () {
      expect(proposal(const TextFile('Meeting notes.txt', 'Line one\nLine two\n')),
          ['Meeting notes', <String>[], 'Line one\nLine two']);
    });

    test('a Markdown heading as the first line is the title', () {
      expect(proposal(const TextFile('x.md', '# Key ideas\n\n- one\n')),
          ['Key ideas', <String>[], '- one']);
    });

    test('an Org file gives its title and tags, not its IDs', () {
      const text = ':PROPERTIES:\n:ID: old-id\n:END:\n'
          '#+title: Garden plan\n#+filetags: :home:green:\n\n'
          'Seeds.\n* Spring\n:PROPERTIES:\n:ID: h1\n:CUSTOM: kept\n:END:\n';
      expect(proposal(const TextFile('garden.org', text)), [
        'Garden plan',
        ['home', 'green'],
        'Seeds.\n* Spring\n:PROPERTIES:\n:CUSTOM: kept\n:END:',
      ]);
    });

    test('an Org heading as the first line is the title', () {
      expect(proposal(const TextFile('x.org', '* Trip\nPack.\r\n')),
          ['Trip', <String>[], 'Pack.']);
    });
  });

  test('joinFiles puts each file under a heading with its name (#220)', () {
    expect(
        joinFiles(const [
          TextFile('one.txt', 'First text.\n'),
          TextFile('two.org',
              ':PROPERTIES:\n:ID: x\n:END:\n#+title: Two\n* Part\nText.\n'),
        ]),
        '* one.txt\nFirst text.\n\n* two.org\n** Part\nText.');
  });

  group('importText (#220)', () {
    test('a file with an ID stays as it is', () {
      const text = ':PROPERTIES:\n:ID:       keep-me\n:END:\n#+title: Kept\n';
      expect(importText(text, 'new'), (id: 'keep-me', text: text));
    });

    test('a file without a drawer gets one with the new ID', () {
      const text = '#+title: Fresh\nBody.\n';
      final imported = importText(text, 'new-id');
      expect(imported.text,
          ':PROPERTIES:\n:ID:       new-id\n:END:\n#+title: Fresh\nBody.\n');
      final parsed = parseRoamFile('roam/fresh.org', imported.text);
      expect(parsed.nodes.single.id, 'new-id');
      expect(parsed.nodes.single.title, 'Fresh');
    });

    test('a top drawer without an ID gets the new ID in it', () {
      const text = ':PROPERTIES:\n:ROAM_ALIASES: Other\n:END:\n#+title: T\n';
      expect(importText(text, 'n1').text,
          ':PROPERTIES:\n:ID:       n1\n:ROAM_ALIASES: Other\n:END:\n#+title: T\n');
    });

    test('an ID only under a heading is not the file\'s ID', () {
      const text = '#+title: T\n* H\n:PROPERTIES:\n:ID: h\n:END:\n';
      expect(importText(text, 'n2').id, 'n2');
    });

    test('Windows line ends stay', () {
      expect(importText('#+title: W\r\n', 'n3').text,
          ':PROPERTIES:\r\n:ID:       n3\r\n:END:\r\n#+title: W\r\n');
    });
  });

  test('sharedTextMessage quotes the text and names the file (#220)', () {
    expect(sharedTextMessage('Line one\n\nLine two\n'),
        'Shared text:\n> Line one\n>\n> Line two\n\n');
    expect(sharedTextMessage('Hi', name: 'a.txt'),
        'Shared text (a.txt):\n> Hi\n\n');
  });
}
