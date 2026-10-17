import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

void main() {
  test('the theme is saved and read back; an unknown one is System (#90)',
      () {
    expect(const ViewSettings().theme, AppTheme.system);
    final back =
        ViewSettings.fromJson(const ViewSettings(theme: AppTheme.dark).toJson());
    expect(back.theme, AppTheme.dark);
    expect(ViewSettings.fromJson({'theme': 'purple'}).theme, AppTheme.system);
    expect(AppTheme.light.mode, ThemeMode.light);
  });

  testWidgets('the Settings page switches the theme at once', (tester) async {
    final store = MemoryViewSettingsStore();
    await tester.pumpWidget(ViewSettingsHost(
      store: store,
      child: Builder(
        builder: (context) => MaterialApp(
          themeMode: ViewSettingsScope.of(context).theme.mode,
          theme: ThemeData(),
          darkTheme: ThemeData(brightness: Brightness.dark),
          home: const SettingsScreen(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final dark = find.byKey(const ValueKey('theme-dark'));
    await tester.scrollUntilVisible(dark, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(dark);
    await tester.pumpAndSettle();
    expect(store.settings.theme, AppTheme.dark);
    expect(Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
        Brightness.dark);
  });
}
