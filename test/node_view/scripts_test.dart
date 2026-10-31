import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/edit/org_toggles.dart' show parseNote;
import 'package:roam_graph_mobile/node_view/scripts.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import 'node_screen_test.dart' show notes, open, orgText;

const _body = 'Names: real_time_streaming and x^2 and H_{2}O and y^{3}.\n';

/// How many subscripts and superscripts [document] has.
int _scriptsIn(OrgDocument document) {
  var count = 0;
  document.visit<OrgSubscript>((_) {
    count++;
    return true;
  });
  document.visit<OrgSuperscript>((_) {
    count++;
    return true;
  });
  return count;
}

OrgDocument _shown(String text, ScriptMode setting) =>
    withScripts(parseNote(text), scriptModeOf(text) ?? setting);

void main() {
  group('the mode of a note (#213)', () {
    test('only with braces keeps the braced scripts', () {
      final document = _shown(_body, ScriptMode.braces);
      expect(_scriptsIn(document), 2);
      expect(document.toMarkup(), _body);
    });

    test('as typed keeps none', () {
      final document = _shown(_body, ScriptMode.never);
      expect(_scriptsIn(document), 0);
      expect(document.toMarkup(), _body);
    });

    test('always keeps all of them', () {
      final document = _shown(_body, ScriptMode.always);
      expect(_scriptsIn(document), greaterThan(2));
      expect(document.toMarkup(), _body);
    });

    test('#+OPTIONS: ^:t, ^:{} and ^:nil win over the setting', () {
      expect(_scriptsIn(_shown('#+OPTIONS: ^:nil\n$_body', ScriptMode.always)),
          0);
      expect(_scriptsIn(_shown('#+OPTIONS: ^:{}\n$_body', ScriptMode.never)),
          2);
      expect(
          _scriptsIn(_shown('#+OPTIONS: ^:t\n$_body', ScriptMode.never)),
          greaterThan(2));
    });

    test('#+OPTIONS: with several items', () {
      const text = '#+title: T\n#+options: toc:nil ^:{} num:nil\n$_body';
      expect(scriptModeOf(text), ScriptMode.braces);
      expect(scriptModeOf('#+OPTIONS: toc:nil ^:nil num:nil\n'),
          ScriptMode.never);
      expect(scriptModeOf('#+OPTIONS: toc:nil num:nil\n'), isNull);
      expect(scriptModeOf('#+OPTIONS: ^:sideways\n'), isNull);
      expect(scriptModeOf('No options here, a^b.\n'), isNull);
    });

    test('the last ^: item wins', () {
      expect(scriptModeOf('#+OPTIONS: ^:t\n#+OPTIONS: ^:nil\n'),
          ScriptMode.never);
    });

    test('a heading node reads the options of the whole file', () {
      const text = '#+OPTIONS: ^:nil\n* Heading\n:PROPERTIES:\n:ID: h\n:END:\n'
          'Text a_{b} here.\n';
      final document = _shown(text, ScriptMode.always);
      expect(_scriptsIn(document), 0);
      expect(document.sectionWithId('h'), isNotNull);
    });

    test('LaTeX and verbatim are not changed', () {
      const text = r'Math $x_i$ and \(y_j\), =a_b=, ~c_d~, e_f.' '\n'
          '#+begin_src python\nsnake_case = 1\n#+end_src\n';
      final document = _shown(text, ScriptMode.never);
      expect(document.toMarkup(), text);
      var latex = 0;
      document.visit<OrgLatexInline>((_) {
        latex++;
        return true;
      });
      expect(latex, 2);
    });
  });

  group('the setting', () {
    test('an old settings file without the key gets the default', () {
      expect(const ViewSettings().scripts, ScriptMode.braces);
      expect(ViewSettings.fromJson({'sectionsOnOpen': 'headings'}).scripts,
          ScriptMode.braces);
      expect(ViewSettings.fromJson({'scripts': 'sideways'}).scripts,
          ScriptMode.braces);
    });

    test('JSON: saved and read back', () {
      for (final mode in ScriptMode.values) {
        final settings = ViewSettings(scripts: mode);
        expect(ViewSettings.fromJson(settings.toJson()), settings);
      }
    });

    testWidgets('the settings page saves the choice', (tester) async {
      // Tall, so all of the View page is on screen.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryViewSettingsStore();
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) =>
            ViewSettingsHost(store: store, child: child!),
        home: const SettingsScreen(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scripts-never')));
      await tester.pumpAndSettle();
      expect(store.settings.scripts, ScriptMode.never);
    });
  });

  group('the note view', () {
    final texts = {
      ...notes,
      'b.org': notes['b.org']!.replaceFirst(
          'Top text of B.\n', 'Top text of B, real_time_streaming.\n'),
    };

    testWidgets('an identifier shows as typed by default', (tester) async {
      await open(tester, 'b', texts: texts);
      expect(orgText('real_time_streaming'), findsOneWidget);
    });

    testWidgets('as typed also shows it as typed', (tester) async {
      await open(tester, 'b', texts: texts, scripts: ScriptMode.never);
      expect(orgText('real_time_streaming'), findsOneWidget);
    });
  });
}
