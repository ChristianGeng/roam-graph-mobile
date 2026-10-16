import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/src_languages.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf, open;

void main() {
  // The languages map to Emacs's modes as org-src-get-lang-mode does in
  // Org 9.7.39 (checked in Emacs), and the modes to highlight.js names.
  test('languages as Emacs colours them', () {
    for (final (language, id) in [
      ('sh', 'bash'), ('shell', 'bash'), ('bash', 'bash'), ('zsh', 'bash'),
      ('elisp', 'lisp'), ('emacs-lisp', 'lisp'), ('js', 'javascript'),
      ('toml', 'ini'), ('conf', 'ini'), ('C', 'c'), ('cpp', 'cpp'),
      ('C++', 'cpp'), ('sqlite', 'sql'), ('python', 'python'),
      ('json', 'json'), ('yaml', 'yaml'), ('makefile', 'makefile'),
    ]) {
      expect(highlightLanguage(language), id, reason: language);
    }
  });

  test('languages Emacs does not colour stay plain', () {
    // Emacs has no config-mode, mermaid has no highlight.js grammar, and
    // text is plain text.
    // Names are compared as written: Emacs has no Python-mode.
    for (final language in [
      'config', 'mermaid', 'text', 'sclang', 'Python', 'dot', 'calc', '',
      null,
    ]) {
      expect(highlightLanguage(language), isNull, reason: language);
    }
  });

  test('blocks get the highlight.js language, shown as written', () {
    const text = '* A\n#+begin_src sh :results output\necho hi\n#+end_src\n'
        '** B\n#+begin_src elisp\n(message "x")\n#+end_src\n'
        '#+begin_src toml\na = 1\n#+end_src\n'
        '#+begin_src mermaid\ngraph TD\n#+end_src\n'
        '#+begin_src Python\nx = 1\n#+end_src\n';
    final document = withHighlightLanguages(OrgDocument.parse(text));
    final languages = <String?>[];
    document.visit<OrgSrcBlock>((block) {
      languages.add(block.language);
      return true;
    });
    // mermaid keeps its name; Python, which the renderer would colour as
    // python, gets none.
    expect(languages, ['bash', 'lisp', 'ini', 'mermaid', '']);
    // Only the language changed: the text, headers included, is as written.
    expect(document.toMarkup(), text);
  });

  testWidgets('an sh block in the node view is coloured', (tester) async {
    const note = ':PROPERTIES:\n:ID: s\n:END:\n#+title: S\n'
        '#+begin_src sh\nif [ -f x ]; then echo "found"; fi\n#+end_src\n';
    await open(tester, 's',
        graph: ValueNotifier(graphOf({'s.org': note})),
        texts: const {'s.org': note});
    final colours = <Color?>{};
    for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
      if (!text.text.toPlainText().contains('found')) continue;
      text.text.visitChildren((span) {
        colours.add(span.style?.color);
        return true;
      });
    }
    // Keywords, strings and plain text in different colours.
    expect(colours.length, greaterThan(1));
  });

  testWidgets('a block Emacs shows plain is plain in the node view',
      (tester) async {
    // python is a highlight.js grammar, but Emacs has no Python-mode.
    const note = ':PROPERTIES:\n:ID: p\n:END:\n#+title: P\n'
        '#+begin_src Python\nif x: print("found")\n#+end_src\n';
    await open(tester, 'p',
        graph: ValueNotifier(graphOf({'p.org': note})),
        texts: const {'p.org': note});
    final colours = <Color?>{};
    for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
      if (!text.text.toPlainText().contains('found')) continue;
      text.text.visitChildren((span) {
        colours.add(span.style?.color);
        return true;
      });
    }
    expect(colours.length, lessThanOrEqualTo(1));
  });

  testWidgets('the colours follow the app: light and dark differ',
      (tester) async {
    const note = ':PROPERTIES:\n:ID: s\n:END:\n#+title: S\n'
        '#+begin_src sh\nif [ -f x ]; then echo "found"; fi\n#+end_src\n';
    Future<Set<Color?>> colours(Brightness brightness) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: NodeScreen(
          graph: ValueNotifier(graphOf({'s.org': note})),
          id: 's',
          readNote: (path) async => note,
          nodeMemory: MemoryNodeMemory(),
        ),
      ));
      await tester.pumpAndSettle();
      final found = <Color?>{};
      for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
        if (!text.text.toPlainText().contains('found')) continue;
        text.text.visitChildren((span) {
          found.add(span.style?.color);
          return true;
        });
      }
      return found;
    }

    final light = await colours(Brightness.light);
    final dark = await colours(Brightness.dark);
    expect(light.length, greaterThan(1));
    expect(dark.length, greaterThan(1));
    expect(dark, isNot(equals(light)));
  });
}
