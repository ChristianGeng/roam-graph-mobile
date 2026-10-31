import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/edit/org_toggles.dart';
import 'package:roam_graph_mobile/node_view/heading_link.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import 'node_screen_test.dart' show graphOf, open, orgText, title;

/// Synthetic notes only (AGENTS.md). Q lives in a folder, and links to its
/// neighbour R in several ways. R has headings with a TODO keyword, a
/// priority, tags and a cookie, and one with a custom ID.
const linkNote = ':PROPERTIES:\n:ID: q\n:END:\n#+title: Q\n'
    'One [[id:r::*Caveats][r caveats]], two [[id:r::#why][r why]], '
    'three [[id:r::Setup][r setup]], four [[id:r::*Nothing here][r nothing]], '
    'five [[id:r::/Intro/][r regexp]], six [[id:r::12][r line]], '
    'seven [[id:r::*method][r method]].\n'
    'Files: [[file:r.org::*Caveats][f caveats]], [[file:r.org][f note]], '
    '[[file:../x.org][f other]], [[file:gone.org][f gone]].\n';

const noteR = ':PROPERTIES:\n:ID: r\n:END:\n#+title: R\nIntro text.\n'
    'Same note: [[*Caveats][in caveats]], [[*Nope][in nope]].\n'
    '* Setup\nSetup text.\n'
    '* TODO [#A] Method  [1/2] :tag:\nMethod text.\n'
    '** Caveats\nCaveats text.\n*** Detail\nDetail text.\n'
    '** Other\nOther text.\n'
    '* Notes\n:PROPERTIES:\n:CUSTOM_ID: why\n:END:\nNotes text.\n';

final linkNotes = {'sub/q.org': linkNote, 'sub/r.org': noteR};

Future<void> openQ(WidgetTester tester,
    {SectionsOnOpen sections = SectionsOnOpen.collapsed}) async {
  await open(tester, 'q',
      texts: linkNotes,
      graph: ValueNotifier(graphOf(linkNotes)),
      sections: sections);
}

Future<void> follow(WidgetTester tester, String text) async {
  await tester.tapOnText(find.textRange.ofSubstring(text));
  await tester.pumpAndSettle();
}

void main() {
  group('what a link names', () {
    test('a title, a custom ID, plain text; other options name nothing', () {
      expect(NodeHeading.fromOption('*Caveats')!.text, 'Caveats');
      expect(NodeHeading.fromOption('*Caveats')!.customId, isFalse);
      expect(NodeHeading.fromOption('#why')!.text, 'why');
      expect(NodeHeading.fromOption('#why')!.customId, isTrue);
      expect(NodeHeading.fromOption('Some text')!.text, 'Some text');
      expect(NodeHeading.fromOption('/regexp/'), isNull);
      expect(NodeHeading.fromOption('12'), isNull);
      expect(NodeHeading.fromOption('(ref:one)'), isNull);
      expect(NodeHeading.fromOption(''), isNull);
      expect(NodeHeading.fromOption(null), isNull);
      expect(NodeHeading.fromOption('*'), isNull);
    });

    test('the message', () {
      expect(const NodeHeading.title('Caveats').missingMessage,
          'The heading "Caveats" is no longer in this note.');
    });
  });

  group('finding the heading', () {
    final doc = OrgDocument.parse(noteR);
    OrgSection? find(NodeHeading heading) => findHeading(doc, heading);
    String? titleOf(OrgSection? s) => s?.headline.rawTitle?.trim();

    test('without TODO keyword, priority, tags, cookie and extra spaces', () {
      expect(titleOf(find(const NodeHeading.title('Method'))),
          startsWith('Method'));
      expect(titleOf(find(const NodeHeading.title('  method '))),
          startsWith('Method'));
      expect(titleOf(find(const NodeHeading.title('Caveats'))), 'Caveats');
    });

    test('a custom ID, and not found', () {
      expect(titleOf(find(const NodeHeading.customId('why'))), 'Notes');
      expect(find(const NodeHeading.customId('nope')), isNull);
      expect(find(const NodeHeading.title('Nope')), isNull);
      expect(find(const NodeHeading.title('Caveats text')), isNull);
    });

    test('the first of several, in the order of the text', () {
      final twice = OrgDocument.parse('* A\nfirst\n* B\n** A\nsecond\n');
      final found = findHeading(twice, const NodeHeading.title('A'))!;
      expect(identical(found, sectionsOf(twice).first), isTrue);
    });

    test('a heading node itself can be the heading', () {
      final one = OrgDocument.parse('* Top\n** Sub\n').sections.first;
      expect(identical(findHeading(one, const NodeHeading.title('Top')), one),
          isTrue);
    });

    test('cookies of both kinds do not count', () {
      expect(headingKey('Plan [2/3]'), 'plan');
      expect(headingKey('Plan [40%]'), 'plan');
      expect(headingKey('Plan   for\tdone'), 'plan for done');
    });
  });

  group('how the sections open', () {
    final doc = OrgDocument.parse(noteR);
    final sections = sectionsOf(doc);
    // Setup, Method, Caveats, Detail, Other, Notes.
    OrgSection named(String start) => sections
        .firstWhere((s) => (s.headline.rawTitle ?? '').trim().startsWith(start));

    test('folded sections above the target open as one-line titles', () {
      final changes = headingFolding(
          doc, named('Detail'), (_) => OrgVisibilityState.folded)!;
      expect([
        for (final (section, state) in changes)
          '${section.headline.rawTitle!.trim().split(' ').first}:${state.name}',
      ], [
        'Method:contents',
        'Caveats:contents',
        'Detail:subtree',
      ]);
    });

    test('a section that already shows its sub-headings stays as it is', () {
      final changes = headingFolding(
          doc,
          named('Detail'),
          (section) => identical(section, named('Method'))
              ? OrgVisibilityState.children
              : OrgVisibilityState.folded)!;
      expect([for (final (section, _) in changes) section],
          [named('Caveats'), named('Detail')]);
    });

    test('a target that is not in the note', () {
      final other = OrgDocument.parse('* Else\n');
      expect(
          headingFolding(doc, other.sections.first,
              (_) => OrgVisibilityState.folded),
          isNull);
    });
  });

  group('the path of a file: link', () {
    test('from the folder of the linking note', () {
      expect(resolveNotePath('sub/q.org', 'r.org'), 'sub/r.org');
      expect(resolveNotePath('q.org', 'r.org'), 'r.org');
      expect(resolveNotePath('sub/q.org', './r.org'), 'sub/r.org');
      expect(resolveNotePath('sub/q.org', '../r.org'), 'r.org');
      expect(resolveNotePath('sub/q.org', 'deep/r.org'), 'sub/deep/r.org');
    });

    test('not for a path outside roam/ or an absolute one', () {
      expect(resolveNotePath('sub/q.org', '../../r.org'), isNull);
      expect(resolveNotePath('q.org', '../r.org'), isNull);
      expect(resolveNotePath('sub/q.org', '/home/me/r.org'), isNull);
      expect(resolveNotePath('sub/q.org', '~/r.org'), isNull);
      expect(resolveNotePath('sub/q.org', ''), isNull);
    });
  });

  group('following a link to a heading (#211)', () {
    testWidgets('the note opens at the heading, unfolded, and its path shows',
        (tester) async {
      await openQ(tester);
      await follow(tester, 'r caveats');
      expect(title('R'), findsOneWidget);
      // The heading and everything under it.
      expect(orgText('Caveats text.'), findsOneWidget);
      expect(orgText('Detail text.'), findsOneWidget);
      // The path to it shows as titles, without its own text.
      expect(orgText('Method'), findsOneWidget);
      expect(orgText('Method text.'), findsNothing);
      // Nothing else opens.
      expect(orgText('Other'), findsOneWidget);
      expect(orgText('Other text.'), findsNothing);
      expect(orgText('Setup text.'), findsNothing);
      expect(orgText('Notes text.'), findsNothing);
      expect(orgText('Intro text.'), findsOneWidget);
    });

    testWidgets('the title is matched without keyword, tags and cookie',
        (tester) async {
      await openQ(tester);
      await follow(tester, 'r method');
      expect(orgText('Method text.'), findsOneWidget);
      expect(orgText('Caveats text.'), findsOneWidget);
      expect(orgText('Detail text.'), findsOneWidget);
      expect(orgText('Setup text.'), findsNothing);
    });

    testWidgets('::#custom-id goes to the heading with that custom ID',
        (tester) async {
      await openQ(tester);
      await follow(tester, 'r why');
      expect(orgText('Notes text.'), findsOneWidget);
      expect(orgText('Method text.'), findsNothing);
    });

    testWidgets('an option without * or # names a title', (tester) async {
      await openQ(tester);
      await follow(tester, 'r setup');
      expect(orgText('Setup text.'), findsOneWidget);
      expect(orgText('Notes text.'), findsNothing);
    });

    testWidgets('a heading that is not there: the top, and a message',
        (tester) async {
      await openQ(tester);
      await follow(tester, 'r nothing');
      expect(title('R'), findsOneWidget);
      expect(find.text('The heading "Nothing here" is no longer in this note.'),
          findsOneWidget);
      expect(orgText('Intro text.'), findsOneWidget);
      expect(orgText('Setup text.'), findsNothing);
    });

    testWidgets('a regexp or a line number opens the top, with no message',
        (tester) async {
      await openQ(tester);
      await follow(tester, 'r regexp');
      expect(title('R'), findsOneWidget);
      expect(find.textContaining('no longer'), findsNothing);
      expect(orgText('Setup text.'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await follow(tester, 'r line');
      expect(title('R'), findsOneWidget);
      expect(find.textContaining('no longer'), findsNothing);
    });

    testWidgets('a file: link to a note of the index opens it at the heading',
        (tester) async {
      await openQ(tester);
      await follow(tester, 'f caveats');
      expect(title('R'), findsOneWidget);
      expect(orgText('Caveats text.'), findsOneWidget);
      expect(orgText('Setup text.'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await follow(tester, 'f note');
      expect(title('R'), findsOneWidget);
      expect(orgText('Intro text.'), findsOneWidget);
      expect(orgText('Caveats text.'), findsNothing);
    });

    testWidgets('other file: links keep their message', (tester) async {
      await openQ(tester);
      await follow(tester, 'f other');
      expect(find.text('This app opens id:, web, mail and phone links, not '
          '"file:../x.org".'), findsOneWidget);
      expect(title('Q'), findsOneWidget);
      await follow(tester, 'f gone');
      expect(find.text('This app opens id:, web, mail and phone links, not '
          '"file:gone.org".'), findsOneWidget);
      expect(title('Q'), findsOneWidget);
    });

    testWidgets('Back returns to the linking note', (tester) async {
      await openQ(tester);
      await follow(tester, 'r caveats');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(title('Q'), findsOneWidget);
    });

    testWidgets('[[*Heading]] in the same note unfolds it there',
        (tester) async {
      await open(tester, 'r',
          texts: linkNotes,
          graph: ValueNotifier(graphOf(linkNotes)),
          sections: SectionsOnOpen.collapsed);
      expect(orgText('Caveats text.'), findsNothing);
      await follow(tester, 'in caveats');
      // No new page: still the one note.
      expect(title('R'), findsOneWidget);
      expect(find.text('This heading is no node, so the app cannot open it.'),
          findsNothing);
      expect(orgText('Caveats text.'), findsOneWidget);
      expect(orgText('Detail text.'), findsOneWidget);
      expect(orgText('Method text.'), findsNothing);
      expect(orgText('Setup text.'), findsNothing);
    });

    testWidgets('[[*Heading]] that is not in the note says so',
        (tester) async {
      await open(tester, 'r',
          texts: linkNotes,
          graph: ValueNotifier(graphOf(linkNotes)),
          sections: SectionsOnOpen.collapsed);
      await follow(tester, 'in nope');
      expect(title('R'), findsOneWidget);
      expect(find.text('The heading "Nope" is no longer in this note.'),
          findsOneWidget);
    });

    testWidgets('the heading is scrolled to the top of the screen',
        (tester) async {
      final filler = List.generate(40, (i) => 'Filler line $i.\n\n').join();
      final long = {
        'l.org': ':PROPERTIES:\n:ID: l\n:END:\n#+title: L\n'
            'Go [[id:m::*Target][to target]].\n',
        'm.org': ':PROPERTIES:\n:ID: m\n:END:\n#+title: M\n'
            '* First\n$filler* Target\nTarget body.\n$filler',
      };
      await open(tester, 'l',
          texts: long, graph: ValueNotifier(graphOf(long)));
      await follow(tester, 'to target');
      expect(title('M'), findsOneWidget);
      expect(tester.getTopLeft(orgText('Target body.')).dy, lessThan(200));
    });
  });
}
