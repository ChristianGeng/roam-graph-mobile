import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/edit_tools.dart';
import 'package:roam_graph_mobile/edit/edit_proposal.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

const fileNode =
    RoamNode(id: 'f', file: 'f.org', level: 0, title: 'F', line: 1);
const h = RoamNode(id: 'h', file: 'f.org', level: 1, title: 'H', line: 6);

const text = ':PROPERTIES:\n:ID: f\n:END:\n#+title: F\n\nIntro.\n'
    '* H\n:PROPERTIES:\n:ID: h\n:END:\nText of H.\n* Next\nEnd.\n';

final graph = RoamGraph.fromFiles(const [
  RoamFileData(path: 'f.org', nodes: [fileNode, h]),
]);

void main() {
  test('append and replace, for a file node and a heading node', () {
    expect(
        applyProposal(text, h,
            const EditProposal(nodeId: 'h', mode: EditMode.append, text: 'More.')),
        text.replaceFirst('Text of H.\n', 'Text of H.\nMore.\n'));
    expect(
        applyProposal(text, h,
            const EditProposal(
                nodeId: 'h', mode: EditMode.replace, text: 'New.\n')),
        text.replaceFirst('Text of H.\n', 'New.\n'));
    // A blank line before the next heading stays, as proposed.
    expect(
        applyProposal(text, h,
            const EditProposal(
                nodeId: 'h', mode: EditMode.replace, text: 'New.\n\n')),
        text.replaceFirst('Text of H.\n', 'New.\n\n'));
    expect(
        applyProposal(text, fileNode,
            const EditProposal(
                nodeId: 'f', mode: EditMode.replace, text: 'Only this.')),
        ':PROPERTIES:\n:ID: f\n:END:\n#+title: F\nOnly this.\n');
  });

  test('a whole note returned by an AI loses its head, which stays', () {
    const shared = ':PROPERTIES:\n:ID: f\n:END:\n#+title: F (revised)\n'
        '\nBetter intro.\n';
    expect(bodyFor(shared, fileNode), '\nBetter intro.\n');
    // Without the node's :ID:, the text is taken as it is.
    expect(bodyFor('#+title: X\nText.\n', fileNode), '#+title: X\nText.\n');
    const heading = '* H\n:PROPERTIES:\n:ID: h\n:END:\nRevised.\n';
    expect(bodyFor(heading, h), 'Revised.\n');
  });

  test('links to IDs that are no node are found', () {
    expect(
        unknownLinkIds('[[id:h][H]] [[id:nope][X]] [[id:nope]] [[id:f::*H]]',
            graph),
        ['nope']);
  });

  group('the propose_edit tool', () {
    test('a proposal for a node the AI may see', () {
      final p = proposalFrom(
          {'node_id': 'h', 'mode': 'append', 'text': 'x', 'reason': ' Why. '},
          graph);
      expect((p.nodeId, p.mode, p.text, p.reason),
          ('h', EditMode.append, 'x', 'Why.'));
    });

    test('a hidden or unknown node, a bad mode or no text is an error', () {
      // The graph the tool gets has the hidden notes removed already.
      for (final args in [
        {'node_id': 'gone', 'mode': 'append', 'text': 'x'},
        {'node_id': 'h', 'mode': 'delete', 'text': 'x'},
        {'node_id': 'h', 'mode': 'replace', 'text': ' '},
        {'mode': 'append', 'text': 'x'},
      ]) {
        expect(() => proposalFrom(args, graph), throwsA(isA<ToolError>()));
      }
    });

    test('its description says that nothing is saved without review', () {
      expect(proposeEditTool.description, contains('Nothing is saved'));
      expect(proposeEditTool.parameters['required'],
          ['node_id', 'mode', 'text']);
    });
  });
}
