import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';

/// A [NoteStore] in memory: replaces only if the hash still matches, as
/// FolderAccess.kt does.
class MemoryNoteStore implements NoteStore {
  MemoryNoteStore(this.files);

  final Map<String, String> files;
  int writes = 0;

  @override
  Future<NoteVersion?> read(String path) async {
    final text = files[path];
    return text == null ? null : NoteVersion.of(utf8.encode(text));
  }

  @override
  Future<SaveResult> replace(String path, NoteVersion base, String text) async {
    final now = files[path];
    if (now == null) return const NoteGone();
    if (contentHash(utf8.encode(now)) != base.hash) {
      return ChangedMeanwhile(await read(path));
    }
    files[path] = text;
    writes++;
    return Saved(path);
  }

  @override
  Future<SaveResult> delete(String path, NoteVersion base) async {
    final now = files[path];
    if (now == null) return const NoteGone();
    if (contentHash(utf8.encode(now)) != base.hash) {
      return ChangedMeanwhile(await read(path));
    }
    files.remove(path);
    writes++;
    return Saved(path);
  }

  @override
  String historyKey(String path) => path;
}

const note = ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\nText.\n'
    '* H\n:PROPERTIES:\n:ID: h\n:END:\nUnder h.\n';

void main() {
  late MemoryNoteStore store;
  late MemoryEditHistory history;
  late NoteEditor editor;
  var clock = DateTime(2026, 10, 17, 12);

  setUp(() {
    store = MemoryNoteStore({'a.org': note});
    history = MemoryEditHistory();
    clock = DateTime(2026, 10, 17, 12);
    editor = NoteEditor(store: store, history: history, now: () {
      clock = clock.add(const Duration(seconds: 1));
      return clock;
    });
  });

  test('an edit of an unchanged file is saved, and the old text kept',
      () async {
    final base = (await editor.read('a.org'))!;
    final edited = base.text.replaceFirst('Text.', 'New text.');
    expect(await editor.save('a.org', base, edited), isA<Saved>());
    expect(store.files['a.org'], edited);
    final kept = await history.versions('a.org');
    expect(kept.single.text, note);
  });

  test('an edit of a file changed meanwhile is refused; nothing written',
      () async {
    final base = (await editor.read('a.org'))!;
    // The laptop changes the note while it is edited on the phone.
    store.files['a.org'] = '$note\nFrom the laptop.\n';
    final result = await editor.save('a.org', base, '${base.text}Mine.\n');
    expect(result, isA<ChangedMeanwhile>());
    expect((result as ChangedMeanwhile).current!.text,
        contains('From the laptop.'));
    expect(store.writes, 0);
    expect(store.files['a.org'], contains('From the laptop.'));
    // A refused edit leaves no kept version behind.
    expect(await history.versions('a.org'), isEmpty);
  });

  test('a file that is gone is reported', () async {
    final base = (await editor.read('a.org'))!;
    store.files.remove('a.org');
    expect(await editor.save('a.org', base, '${base.text}x\n'), isA<NoteGone>());
    expect(await history.versions('a.org'), isEmpty);
  });

  test('the same text is not written', () async {
    final base = (await editor.read('a.org'))!;
    expect(await editor.save('a.org', base, base.text), isA<NothingToSave>());
    expect(store.writes, 0);
  });

  test('an :ID: or a property drawer cannot be changed (rule 5)', () async {
    final base = (await editor.read('a.org'))!;
    for (final edited in [
      note.replaceFirst(':ID: h', ':ID: other'),
      note.replaceFirst('* H\n:PROPERTIES:\n:ID: h\n:END:\n', '* H\n'),
      note.replaceFirst(':END:\n#+title', ':ROAM_ALIASES: X\n:END:\n#+title'),
    ]) {
      expect(await editor.save('a.org', base, edited),
          isA<LockedPartChanged>());
    }
    expect(store.writes, 0);
  });

  test('a file that is not UTF-8 cannot be edited', () {
    expect(NoteVersion.of([0xff, 0xfe, 0x41]), isNull);
    expect(NoteVersion.of(utf8.encode('ä')), isNotNull);
  });

  test('the hash is SHA-256 of the bytes', () {
    expect(contentHash(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  test('property drawers are found in order, with the line before them',
      () {
    expect(propertyDrawers(note), [
      '\n:PROPERTIES:\n:ID: a\n:END:',
      '* H\n:PROPERTIES:\n:ID: h\n:END:',
    ]);
  });

  test('a drawer moved under another heading, or cut off from its heading, '
      'is refused', () async {
    const two = '* First\n:PROPERTIES:\n:ID: a\n:END:\n* Second\n';
    store.files['b.org'] = two;
    final base = (await editor.read('b.org'))!;
    for (final edited in [
      '* First\n* Second\n:PROPERTIES:\n:ID: a\n:END:\n',
      '* First\nText.\n:PROPERTIES:\n:ID: a\n:END:\n* Second\n',
    ]) {
      expect(await editor.save('b.org', base, edited),
          isA<LockedPartChanged>());
    }
    // Text after the drawer is fine.
    expect(await editor.save('b.org', base, '${two}Text.\n'), isA<Saved>());
  });

  test('a refused save at the limit loses no kept version', () async {
    for (var i = 0; i < keptVersionsPerNote; i++) {
      final base = (await editor.read('a.org'))!;
      expect(await editor.save('a.org', base, '${base.text}$i\n'),
          isA<Saved>());
    }
    final kept = await history.versions('a.org');
    expect(kept, hasLength(keptVersionsPerNote));
    final base = (await editor.read('a.org'))!;
    store.files['a.org'] = '${store.files['a.org']}laptop\n';
    expect(await editor.save('a.org', base, '${base.text}x\n'),
        isA<ChangedMeanwhile>());
    expect([for (final v in await history.versions('a.org')) v.text],
        [for (final v in kept) v.text]);
  });

  test('two versions kept at the same time get their own times', () async {
    final same = DateTime(2026, 10, 17);
    final first = await history.keep('k', 'one', same);
    final second = await history.keep('k', 'two', same);
    expect(second, isNot(first));
    await history.forget('k', first);
    expect([for (final v in await history.versions('k')) v.text], ['two']);
  });

  group('kept versions in files', () {
    late Directory root;
    setUp(() async => root = await Directory.systemTemp.createTemp('hist'));
    tearDown(() => root.delete(recursive: true));

    test('newest first, at most $keptVersionsPerNote per note', () async {
      final files = FileEditHistory(root: root);
      final start = DateTime(2026, 10, 17);
      for (var i = 0; i < keptVersionsPerNote + 5; i++) {
        await files.keep('roam/a.org', 'version $i',
            start.add(Duration(minutes: i)));
      }
      // Nothing is removed until a save succeeded.
      expect(await files.versions('roam/a.org'),
          hasLength(keptVersionsPerNote + 5));
      await files.prune('roam/a.org');
      await files.keep('roam/b.org', 'other', start);
      final kept = await files.versions('roam/a.org');
      expect(kept, hasLength(keptVersionsPerNote));
      expect(kept.first.text, 'version ${keptVersionsPerNote + 4}');
      expect(kept.last.text, 'version 5');
      expect((await files.versions('roam/b.org')).single.text, 'other');

      await files.forget('roam/a.org', kept.first.time);
      expect((await files.versions('roam/a.org')).first.text,
          'version ${keptVersionsPerNote + 3}');
    });
  });
}
