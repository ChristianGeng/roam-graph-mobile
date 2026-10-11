import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/main.dart';

void main() {
  testWidgets('home screen shows the app name and version', (tester) async {
    await tester.pumpWidget(const RoamGraphApp());

    expect(find.text('Roam Graph'), findsWidgets);
    expect(find.textContaining('Version'), findsOneWidget);
  });
}
