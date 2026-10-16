import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/capture/share_inbox.dart';

void main() {
  test('the first line is the title, the rest the text', () {
    expect(proposeNode(const SharedText('\n  Attention\nIs all you need.\n')),
        (title: 'Attention', body: 'Is all you need.'));
  });

  test('a Markdown heading or bold first line, as AI apps share', () {
    expect(proposeNode(const SharedText('## Key ideas\n\n- one\n- two')),
        (title: 'Key ideas', body: '- one\n- two'));
    expect(proposeNode(const SharedText('**Summary**\nText')),
        (title: 'Summary', body: 'Text'));
    // A bold lead-in, and bold inside: only pairs of ** go.
    expect(
        proposeNode(const SharedText('**Summary:** the main points\nMore')),
        (title: 'Summary: the main points', body: 'More'));
    expect(proposeNode(const SharedText('A **bold** word')).title,
        'A bold word');
    expect(proposeNode(const SharedText('5 ** 2')).title, '5 ** 2');
  });

  test('an Org heading first line, as the AI chat writes (#60)', () {
    expect(proposeNode(const SharedText('* Meeting notes\nAgenda')),
        (title: 'Meeting notes', body: 'Agenda'));
    expect(proposeNode(const SharedText('** Deeper')).title, 'Deeper');
    // Org bold is no heading.
    expect(proposeNode(const SharedText('*Bold* start')).title, '*Bold* start');
  });

  test('a subject is the title, and all of the text the body', () {
    expect(
        proposeNode(const SharedText('Line one\nLine two', subject: ' Chat ')),
        (title: 'Chat', body: 'Line one\nLine two'));
  });

  test('nothing shared', () {
    expect(proposeNode(const SharedText('  \n ')), (title: '', body: ''));
  });
}
