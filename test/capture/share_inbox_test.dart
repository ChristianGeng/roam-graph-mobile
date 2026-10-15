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
