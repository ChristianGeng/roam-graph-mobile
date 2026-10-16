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
      '[[id:diary::*Top][(hidden)]].\n',
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
}
