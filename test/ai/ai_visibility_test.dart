import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/graph/ai_share.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

/// Synthetic notes: "Plan" links to the private "Diary" and to "Ideas";
/// "Ideas" has a private heading without an ID and a private heading
/// node; "Diary" links back to "Plan".
const notes = {
  'plan.org': ':PROPERTIES:\n:ID: plan\n:END:\n#+title: Plan\n'
      'See [[id:diary][My diary]] and [[id:ideas][Ideas]].\n',
  'diary.org': ':PROPERTIES:\n:ID: diary\n:END:\n#+title: My diary\n'
      '#+filetags: :private:\nBack to [[id:plan][Plan]].\n',
  'ideas.org': ':PROPERTIES:\n:ID: ideas\n:END:\n#+title: Ideas\n'
      'Open text.\n'
      '* Salary talk :work:private:\nNumbers.\n** Details\nMore numbers.\n'
      '* Health\n:PROPERTIES:\n:ID: health\n:END:\nTagged below.\n'
      '** Doctor :private:\n:PROPERTIES:\n:ID: doctor\n:END:\nVisit.\n'
      '* Public part\nSee [[id:doctor]] and [[id:diary::*Top][the diary]].\n',
};

RoamGraph graphOf(Map<String, String> texts) => RoamGraph.fromFiles([
      for (final MapEntry(:key, :value) in texts.entries)
        parseRoamFile(key, value),
    ]);

void main() {
  final graph = graphOf(notes);
  const private = AiVisibility({'private'});

  test('a node is hidden by its own or an inherited tag', () {
    expect(private.hides(graph.nodes['diary']!), isTrue);
    expect(private.hides(graph.nodes['doctor']!), isTrue);
    expect(private.hides(graph.nodes['plan']!), isFalse);
    expect(private.hides(graph.nodes['health']!), isFalse);
    // Tags are compared as written, as in Org.
    expect(const AiVisibility({'Private'}).hides(graph.nodes['diary']!),
        isFalse);
  });

  test('the visible graph has no hidden node and no link to one', () {
    final visible = private.visibleGraph(graph);
    expect(visible.nodes.keys.toSet(), {'plan', 'ideas', 'health'});
    expect([for (final l in visible.links) '${l.source}->${l.dest}'],
        ['plan->ideas']);
    expect(identical(AiVisibility.none.visibleGraph(graph), graph), isTrue);
  });

  test('hidden headings and the titles of hidden notes leave the text', () {
    final text = private.filterText(notes['ideas.org']!, {'diary', 'doctor'});
    expect(text, isNot(contains('Salary')));
    expect(text, isNot(contains('numbers')));
    expect(text, isNot(contains('Doctor')));
    expect(text, isNot(contains('Visit')));
    expect(text, isNot(contains('the diary')));
    expect(
      text,
      ':PROPERTIES:\n:ID: ideas\n:END:\n#+title: Ideas\nOpen text.\n'
      '* (hidden)\n'
      '* Health\n:PROPERTIES:\n:ID: health\n:END:\nTagged below.\n'
      '** (hidden)\n'
      '* Public part\nSee [[id:doctor][(hidden)]] and '
      '[[id:diary][(hidden)]].\n',
    );
    // Nothing hidden: the text as it is.
    expect(AiVisibility.none.filterText(notes['ideas.org']!, {'diary'}),
        notes['ideas.org']);
  });

  test('a heading line inside a block counts, as in Org', () {
    const text = '#+begin_src org\n* Secret :private:\nx\n#+end_src\nAfter.\n';
    expect(private.filterText(text, const {}), '#+begin_src org\n* (hidden)');
  });

  test('the graph export leaves hidden nodes out and says so', () {
    final text = graphForAi(graph, visibility: private);
    expect(text, startsWith('# My org-roam graph: 3 nodes, 1 links\n'));
    expect(text, contains('2 notes are hidden from AI by their tags, so the '
        'graph is not complete.\n'));
    expect(text, isNot(contains('diary')));
    expect(text, isNot(contains('Doctor')));
    // Without hidden nodes the header has no such line.
    expect(graphForAi(graph), isNot(contains('hidden')));
  });

  test('a node share hides links, backlinks and headings', () {
    final text = nodesForAi(
      graph,
      [
        (graph.nodes['plan']!, notes['plan.org']),
        (graph.nodes['ideas']!, notes['ideas.org']),
      ],
      visibility: private,
    );
    expect(text, contains('- Links to: [[id:ideas][Ideas]]\n'));
    // Diary links to Plan, but Diary is hidden.
    expect(text, contains('- Linked from: none\n'));
    expect(text, contains('See [[id:diary][(hidden)]] and [[id:ideas][Ideas]]'));
    expect(text, isNot(contains('My diary')));
    expect(text, isNot(contains('Salary')));
  });

  test('a visible heading node keeps its subtree, without hidden headings',
      () {
    final text = nodesForAi(
        graph, [(graph.nodes['health']!, notes['ideas.org'])],
        visibility: private);
    expect(text, contains('* Health\n'));
    expect(text, contains('** (hidden)\n'));
    expect(text, isNot(contains('Visit')));
  });

  group('review findings on #61', () {
    test('CRLF files: hidden headings are found too', () {
      const text = '#+title: X\r\nOpen.\r\n* Salary :private:\r\nNumbers.\r\n'
          '* Public\r\nYes.\r\n';
      expect(private.filterText(text, const {}),
          '#+title: X\nOpen.\n* (hidden)\n* Public\nYes.\n');
    });

    test('stars and a tab are no heading, as in Org', () {
      const text = 'Open.\n*\tnot a heading :private:\nStill open.\n';
      expect(private.filterText(text, const {}), text);
    });

    test('escaped links and search options of hidden notes', () {
      const hiddenIds = {'d]x', 'diary'};
      expect(
          private.filterText(
              r'See [[id:d\]x][Diary title]] and [[id:diary::*My diary][x]].',
              hiddenIds),
          'See [[id:d]x][(hidden)]] and [[id:diary][(hidden)]].');
      // Other links stay as written.
      expect(private.filterText(r'[[id:plan::*Top][Plan]]', hiddenIds),
          r'[[id:plan::*Top][Plan]]');
    });

    test('of two nodes with one ID, the graph\'s own decides', () {
      final g = graphOf({
        'a.org': ':PROPERTIES:\n:ID: shared\n:END:\n#+title: Open copy\n',
        'b.org': ':PROPERTIES:\n:ID: shared\n:END:\n#+title: Private copy\n'
            '#+filetags: :private:\n',
        'c.org': ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\n[[id:shared][S]]\n',
      });
      expect(g.nodes['shared']!.title, 'Open copy');
      final visible = private.visibleGraph(g);
      expect(visible.nodes.keys.toSet(), {'shared', 'c'});
      expect(visible.links.single.dest, 'shared');
    });

    test('a file that is hidden now, though the index is older', () {
      final plan = graph.nodes['plan']!;
      expect(private.hidesInText(plan, notes['plan.org']!), isFalse);
      final changed = notes['plan.org']!.replaceFirst(
          '#+title: Plan\n', '#+title: Plan\n#+filetags: :work:private:\n');
      expect(private.hidesInText(plan, changed), isTrue);
      // A heading node whose heading, or a heading above it, is now hidden.
      final health = graph.nodes['health']!;
      expect(private.hidesInText(health, notes['ideas.org']!), isFalse);
      expect(
          private.hidesInText(health,
              notes['ideas.org']!.replaceFirst('* Health\n', '* Health :private:\n')),
          isTrue);
      expect(
          private.hidesInText(health,
              'Top.\n* Parent :private:\n** Health\n:PROPERTIES:\n:ID: health\n:END:\n'),
          isTrue);
      expect(
          private.hidesInText(health,
              '* Before :private:\nx\n* Health\n:PROPERTIES:\n:ID: health\n:END:\n'),
          isFalse);

      // Left out completely: no title, ID, file or tags (#61 review).
      final text = nodesForAi(graph, [(plan, changed), (graph.nodes['ideas']!,
          notes['ideas.org'])], visibility: private);
      expect(text, startsWith('# A note from my org-roam graph'));
      expect(text, isNot(contains('## Plan')));
      expect(text, isNot(contains('plan.org')));
      expect(text, contains('## Ideas'));
    });

    test('links only under a hidden heading are not listed', () {
      final g = graphOf({
        'top.org': ':PROPERTIES:\n:ID: top\n:END:\n#+title: Top\n'
            '[[id:open][Open]]\n* Secret :private:\n[[id:other][Other]]\n',
        'open.org': ':PROPERTIES:\n:ID: open\n:END:\n#+title: Open\n',
        'other.org': ':PROPERTIES:\n:ID: other\n:END:\n#+title: Other\n',
      });
      final text = nodesForAi(
          g,
          [
            (
              g.nodes['top']!,
              ':PROPERTIES:\n:ID: top\n:END:\n#+title: Top\n'
                  '[[id:open][Open]]\n* Secret :private:\n[[id:other][Other]]\n',
            ),
          ],
          visibility: private);
      expect(text, contains('- Links to: [[id:open][Open]]\n'));
      expect(text, isNot(contains('Other')));
    });

    test('"Links to" reads the link targets, not parts of them', () {
      const top = ':PROPERTIES:\n:ID: top\n:END:\n#+title: Top\n'
          '[[id:openness][Openness]] and [[id:d\\]x][escaped]]\n'
          '* Secret :private:\n[[id:open][Open]]\n';
      final g = graphOf({
        'top.org': top,
        'open.org': ':PROPERTIES:\n:ID: open\n:END:\n#+title: Open\n',
        'openness.org': ':PROPERTIES:\n:ID: openness\n:END:\n'
            '#+title: Openness\n',
      });
      final text =
          nodesForAi(g, [(g.nodes['top']!, top)], visibility: private);
      final linksTo =
          text.split('\n').firstWhere((l) => l.startsWith('- Links to:'));
      expect(linksTo, contains('[[id:openness][Openness]]'));
      expect(linksTo, isNot(contains('[[id:open][')));
      expect(idLinkTargets(r'[[id:d\]x][e]] [[id:a::*T][t]] [[file:x]]'),
          {'d]x', 'a'});
    });
  });
}
