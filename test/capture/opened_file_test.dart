import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/capture/opened_file.dart';
import 'package:roam_graph_mobile/capture/share_inbox.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

const _alpha = ':PROPERTIES:\n:ID:       aaaa-1111\n:END:\n#+title: Alpha\n\n'
    'Alpha text, see [[id:bbbb-2222][Beta]].\n';
const _beta = ':PROPERTIES:\n:ID: bbbb-2222\n:END:\n#+title: Beta\n\n* A heading\n'
    ':PROPERTIES:\n:ID: cccc-3333\n:END:\nInside.\n';

void main() {
  final notes = {
    '20240101000000-alpha.org': _alpha,
    'sub/20240102000000-beta.org': _beta,
  };
  final graph = RoamGraph.fromFiles([
    for (final MapEntry(:key, :value) in notes.entries)
      parseRoamFile(key, value),
  ]);
  Future<String?> readNote(String path) async => notes[path];

  group('what an opened file is taken as', () {
    test('Org files by name, whatever type the file manager sends', () {
      expect(openedKind('x.org', 'application/octet-stream'), OpenedKind.org);
      expect(openedKind('X.ORG', 'text/plain'), OpenedKind.org);
      expect(openedKind('x.org', null), OpenedKind.org);
    });

    test('recordings by type or name', () {
      expect(openedKind('memo.m4a', null), OpenedKind.audio);
      expect(openedKind('memo', 'audio/ogg'), OpenedKind.audio);
    });

    test('anything else is neither', () {
      expect(openedKind('list.txt', 'text/plain'), OpenedKind.other);
      expect(openedKind('a.pdf', 'application/octet-stream'), OpenedKind.other);
    });
  });

  test('the :ID: values of a file, in order', () {
    expect(orgIds(_beta), ['bbbb-2222', 'cccc-3333']);
    expect(orgIds('no ids here\n:id: lower-case\n'), ['lower-case']);
  });

  group('inside or outside the notes folder', () {
    test('a note of the folder opens as its file node', () async {
      final route = await routeOpenedOrg(graph, _alpha, readNote);
      expect(route, isA<InNotes>());
      expect((route as InNotes).id, 'aaaa-1111');
      expect(route.file, '20240101000000-alpha.org');
    });

    test('line ends and trailing white space do not count', () async {
      final crlf = '${_beta.replaceAll('\n', '\r\n')}\n\n';
      final route = await routeOpenedOrg(graph, crlf, readNote);
      // The file node, not the heading's ID that comes later.
      expect((route as InNotes).id, 'bbbb-2222');
    });

    test('a copy with other text is shown from outside', () async {
      final route = await routeOpenedOrg(
          graph, _alpha.replaceFirst('Alpha text', 'Changed'), readNote);
      expect(route, isA<OutsideNotes>());
      expect((route as OutsideNotes).unknownIds, isFalse);
    });

    test('IDs the index does not know may mean a new note: scan', () async {
      final route = await routeOpenedOrg(
          graph, ':PROPERTIES:\n:ID: new-9999\n:END:\n#+title: New\n', readNote);
      expect((route as OutsideNotes).unknownIds, isTrue);
    });

    test('a file without IDs is from outside, with no scan', () async {
      final route = await routeOpenedOrg(graph, '* Just Org\nText\n', readNote);
      expect((route as OutsideNotes).unknownIds, isFalse);
    });

    test('a note that cannot be read is not taken for the file', () async {
      final route =
          await routeOpenedOrg(graph, _alpha, (path) async => null);
      expect(route, isA<OutsideNotes>());
    });
  });

  group('a file from outside, for the read-only view', () {
    test('an org-roam note keeps its own nodes', () {
      final data = viewedFile('alpha.org', _alpha);
      expect(data.path, 'opened/alpha.org');
      expect([for (final n in data.nodes) n.id], ['aaaa-1111']);
      expect(data.links.single.dest, 'bbbb-2222');
    });

    test('a plain Org file gets a file node, titled by #+title or name', () {
      final titled = viewedFile('plan.org', '#+title: The plan\n* Step\n');
      expect(titled.nodes.single.id, openedFileId('plan.org'));
      expect(titled.nodes.single.level, 0);
      expect(titled.nodes.single.title, 'The plan');
      expect(viewedFile('plan.org', '* Step\n').nodes.single.title, 'plan');
    });

    test('heading nodes only: a file node in front of them', () {
      final data = viewedFile(
          'h.org', '* Only\n:PROPERTIES:\n:ID: hhhh\n:END:\nText\n');
      expect([for (final n in data.nodes) n.id], [openedFileId('h.org'), 'hhhh']);
    });
  });

  group('the share inbox marks files opened with the app', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('roam_graph/share');

    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    Future<Share?> take(Map<String, Object?> answer) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => answer);
      return const PlatformShareInbox().take();
    }

    test('"Open with" files are opened, shared files are not', () async {
      final file = {'name': 'a.org', 'mimeType': 'application/octet-stream'};
      final opened = await take({'files': [file], 'view': true});
      expect((opened as SharedFiles).opened, isTrue);
      expect(opened.files.single.name, 'a.org');
      final shared = await take({'files': [file]});
      expect((shared as SharedFiles).opened, isFalse);
    });
  });
}
