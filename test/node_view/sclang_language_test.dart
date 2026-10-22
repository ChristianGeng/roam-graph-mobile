import 'package:flutter_test/flutter_test.dart';
import 'package:highlighting/highlighting.dart';
import 'package:highlighting/languages/all.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/node_view/sclang_language.dart';
import 'package:roam_graph_mobile/node_view/src_languages.dart';

import 'node_screen_test.dart' show graphOf, open;

/// Each coloured piece of [code] as (class, text): every node with a class,
/// with all the text inside it, outer nodes before inner ones.
List<(String, String)> pieces(String code) {
  String text(Node node) =>
      node.value ?? node.children.map(text).join();
  final found = <(String, String)>[];
  void visit(Node node) {
    if (node.className != null) found.add((node.className!, text(node)));
    node.children.forEach(visit);
  }

  highlight.parse(code, languageId: 'sclang').nodes!.forEach(visit);
  return found;
}

// Synthetic SuperCollider code, not from real notes.
const code = '// a line comment\n'
    '/* outer /* inner */ still outer */\n'
    '(\n'
    'var freq = 440, amp = 0.5;\n'
    '~bus = Bus.audio(s, 2);\n'
    'SynthDef(\\beep, { |out = 0|\n'
    '    Out.ar(out, SinOsc.ar(freq * 2pi, 0, amp) * -12.dbamp);\n'
    '}).add;\n'
    '"a \\"quoted\\" string".postln;\n'
    "'name'.postln; \$a.postln; 16rFF; 0x1F; 1e3; this; nil; inf; true;\n"
    ')\n';

void main() {
  test('sclang has its own grammar', () {
    expect(highlightLanguage('sclang'), 'sclang');
    expect(allLanguages['sclang'], same(sclang));
  });

  test('supercollider and sc stay plain: Emacs has no such modes', () {
    expect(highlightLanguage('supercollider'), isNull);
    expect(highlightLanguage('sc'), isNull);
  });

  test('a SuperCollider block is split into the kinds sclang-mode colours',
      () {
    registerSclang();
    final found = pieces(code);
    for (final piece in [
      ('comment', '// a line comment'),
      // Nested block comments are one comment.
      ('comment', '/* outer /* inner */ still outer */'),
      ('keyword', 'var'),
      ('number', '440'),
      ('number', '0.5'),
      ('variable', '~bus'),
      ('type', 'Bus'),
      ('type', 'SynthDef'),
      ('symbol', r'\beep'),
      ('type', 'Out'),
      ('type', 'SinOsc'),
      ('number', '2pi'),
      ('number', '12'),
      ('string', r'"a \"quoted\" string"'),
      ('symbol', "'name'"),
      ('string', r'$a'),
      ('number', '16rFF'),
      ('number', '0x1F'),
      ('number', '1e3'),
      ('built_in', 'this'),
      ('literal', 'nil'),
      ('literal', 'inf'),
      ('literal', 'true'),
    ]) {
      expect(found, contains(piece), reason: '$piece');
    }
    // The inner comment does not end the outer one.
    expect(found.where((p) => p.$2 == ' still outer */'), isEmpty);
    // Plain words stay plain: no piece is only `freq`, `amp` or `postln`.
    for (final word in ['freq', 'amp', 'postln', 'dbamp']) {
      expect(found.map((p) => p.$2), isNot(contains(word)), reason: word);
    }
  });

  test('registering twice does no harm', () {
    registerSclang();
    registerSclang();
    expect(allLanguages['sclang'], same(sclang));
    expect(pieces('SinOsc.ar(440)'),
        containsAll([('type', 'SinOsc'), ('number', '440')]));
  });

  testWidgets('an sclang block in the node view is coloured', (tester) async {
    const note = ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\n'
        '#+begin_src sclang\n'
        '~found = SinOsc.ar(440, 0, 0.5); // found\n'
        '#+end_src\n';
    await open(tester, 'c',
        graph: ValueNotifier(graphOf({'c.org': note})),
        texts: const {'c.org': note});
    final colours = <Color?>{};
    for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
      if (!text.text.toPlainText().contains('found')) continue;
      text.text.visitChildren((span) {
        colours.add(span.style?.color);
        return true;
      });
    }
    // The variable, the class, the numbers and the comment in colours.
    expect(colours.length, greaterThan(2));
  });
}
