import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart' show HttpReply;
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/chat_list_screen.dart';
import 'package:roam_graph_mobile/ai/chat_store.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';

import 'ai_chat_test.dart' show FakeServer;
import 'ai_settings_test.dart' show MemoryAiSettingsStore;
import 'ai_visibility_test.dart' show graphOf, notes;
import 'chat_list_screen_test.dart' show chatFile;
import 'chat_screen_test.dart' show keysWithAnthropic;

void main() {
  testWidgets('dbg rename', (tester) async {
    final storage = MemoryChatStorage()
      ..files['newer'] =
          chatFile('Newer chat', lastUsed: '2026-10-02T10:00:00.000Z');
    final store = ChatStore(storage);
    await store.load();
    debugPrint('DBG loaded');
    await tester.pumpWidget(AiSettingsHost(
      store: MemoryAiSettingsStore(),
      keys: keysWithAnthropic(),
      child: ChatStoreScope(
        store: store,
        child: MaterialApp(
          home: ChatListScreen(
            graph: ValueNotifier(graphOf(notes)),
            readNote: (path) async => notes[path],
            post: FakeServer([]).post,
            agentLog: MemoryAgentLog(),
            getModels: (url, headers) async => const HttpReply(404, ''),
          ),
        ),
      ),
    ));
    debugPrint('DBG pumped widget');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    debugPrint('DBG list up');
    await tester.tap(find.byKey(const ValueKey('chat-menu-newer')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    debugPrint('DBG menu open');
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    debugPrint('DBG dialog open ${find.byKey(const ValueKey('chat-rename-field')).evaluate().length}');
    await tester.enterText(
        find.byKey(const ValueKey('chat-rename-field')), 'Mushrooms');
    await tester.pump();
    debugPrint('DBG typed');
    await tester.tap(find.byKey(const ValueKey('chat-rename-ok')));
    await tester.pump();
    debugPrint('DBG tapped ok');
    await tester.pump(const Duration(seconds: 1));
    debugPrint('DBG closed ${find.text('Mushrooms').evaluate().length}');
    var n = 0;
    while (tester.binding.hasScheduledFrame && n < 50) {
      await tester.pump(const Duration(milliseconds: 100));
      n++;
    }
    debugPrint('DBG settled after $n frames');
    await store.flush();
    debugPrint('DBG flushed');
  });
}
