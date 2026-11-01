/// Confirmation and grouped undo for hand deletion (#171).
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show GestureBinding;
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, KeyDownEvent;

import '../capture/capture_screen.dart';
import '../graph/roam_graph.dart';
import '../platform/error_text.dart';
import 'agent_changes.dart';
import 'delete_node.dart';

class HandDeletion {
  HandDeletion(this.changes, this.report);
  final AgentChanges changes;
  final DeleteReport report;
}

/// Captures the file versions before showing the choice. Confirmation
/// never rereads a target to silently accept a newer file.
Future<HandDeletion?> confirmDeleteNotes(
  BuildContext context, {
  required RoamGraph graph,
  required List<RoamNode> nodes,
  required NoteWriter writer,
  Map<String, (int, int)> alsoLines = const {},
  Map<String, String> alsoText = const {},
  String? heading,
}) async {
  final editor = writer.editor;
  if (editor == null || nodes.isEmpty) return null;
  final time = DateTime.now();
  final changes = AgentChanges(
    messageId: 'delete-${time.microsecondsSinceEpoch}',
    prompt: nodes.length == 1
        ? "Delete '${nodes.single.displayTitle}'"
        : 'Delete ${nodes.length} notes',
    time: time,
  );
  final deleter = NodeDeleter(
    editor: editor,
    record: (node, before, after, removed, key) async {
      final change = AgentChange(
        tool: 'hand_delete',
        path: node.file,
        noteKey: key,
        nodeId: node.id,
        title: node.displayTitle,
        before: before,
        after: after,
        removed: removed,
      );
      changes.changes.add(change);
      await writer.changeLog.record(
        AgentLogEntry.of(
          changes,
          change,
          key.split('\n').first,
          DateTime.now(),
        ),
      );
    },
  );
  final DeletePlan plan;
  try {
    plan = await deleter.prepare(graph, nodes,
        alsoLines: alsoLines, alsoText: alsoText);
  } on DeleteError catch (e) {
    if (context.mounted) {
      showErrorSnackBar(ScaffoldMessenger.of(context), e.message);
    }
    return null;
  }
  if (!context.mounted) return null;
  return showDialog<HandDeletion>(
    context: context,
    builder: (_) =>
        _DeleteDialog(
            plan: plan, deleter: deleter, changes: changes, heading: heading),
  );
}

class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({
    required this.plan,
    required this.deleter,
    required this.changes,
    this.heading,
  });
  final DeletePlan plan;

  /// The heading without an ID that is deleted with the nodes in its
  /// subtree (#217), if any.
  final String? heading;
  final NodeDeleter deleter;
  final AgentChanges changes;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  bool _plainText = true;
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.deleter.apply(
        widget.plan,
        turnLinksIntoText: _plainText,
      );
      if (!mounted) return;
      if (report.deleted.isEmpty) {
        setState(() => _error = report.failures.join('\n'));
        return;
      }
      Navigator.pop(context, HandDeletion(widget.changes, report));
    } on Exception catch (e) {
      if (mounted) setState(() => _error = 'Could not finish deleting: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final nodes = plan.targets;
    final heading = widget.heading;
    final only = nodes.length == 1 && heading == null ? nodes.single : null;
    final headings = only != null && only.isFile ? plan.gone.length - 1 : 0;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(
          heading != null
              ? "Delete the heading '$heading'?"
              : only == null
              ? 'Delete ${nodes.length} notes?'
              : "Delete '${only.displayTitle}'?",
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (only != null)
                Text(
                  only.isFile
                      ? 'The file ${only.file} will be deleted'
                      : 'The heading and its subtree will be removed from ${only.file}',
                ),
              if (headings > 0)
                Text(
                  '$headings ${headings == 1 ? 'heading node' : 'heading nodes'} '
                  'in this file will also be deleted.',
                ),
              if (heading != null)
                Text(
                  'The heading and its subtree will be removed from '
                  '${nodes.first.file}, with '
                  '${nodes.length == 1 ? 'this note' : 'these ${nodes.length} notes'}:',
                ),
              if (only == null) ...[
                for (final node in nodes.take(10)) Text(node.displayTitle),
                if (nodes.length > 10) Text('and ${nodes.length - 10} more'),
              ],
              Text(
                '${plan.linkingNotes} '
                '${plan.linkingNotes == 1 ? 'note links' : 'notes link'} to it',
              ),
              RadioGroup<bool>(
                groupValue: _plainText,
                onChanged: (value) {
                  if (!_busy && value != null) {
                    setState(() => _plainText = value);
                  }
                },
                child: const Column(
                  children: [
                    RadioListTile<bool>(
                      value: true,
                      title: Text('Turn the links into plain text'),
                    ),
                    RadioListTile<bool>(
                      value: false,
                      title: Text('Leave the links'),
                    ),
                  ],
                ),
              ),
              if (_error != null) Text(_error!),
              if (_busy) const CircularProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: _busy ? null : _delete,
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

/// The delete confirmation is intentionally persistent: its target is
/// gone. The next action dismisses it, or it can be swiped away.
Future<void> showDeleted(
  ScaffoldMessengerState messenger,
  HandDeletion deletion,
  NoteWriter writer,
) async {
  // Own saves can rebuild the side pane and end its quick-edit visit.
  // Let that frame's snack-bar cleanup finish before offering this Undo.
  await WidgetsBinding.instance.endOfFrame;
  if (!messenger.mounted) return;
  final report = deletion.report;
  final title = report.deleted.length == 1
      ? "Deleted '${report.deleted.single.displayTitle}'"
      : 'Deleted ${report.deleted.length} notes';
  final warnings = [
    ...report.failures,
    if (report.left.isNotEmpty)
      'Links left unchanged in: ${report.left.join(', ')}.',
  ];
  // A messenger can show this snack bar in both Scaffolds during a
  // route transition. Track each built copy without sharing a GlobalKey.
  final snackContexts = <BuildContext>{};
  var undoing = false;
  messenger.clearSnackBars();
  messenger.removeCurrentSnackBar();
  final controller = messenger.showSnackBar(
    SnackBar(
      persist: true,
      content: Builder(
        builder: (context) {
          snackContexts.removeWhere((c) => !c.mounted);
          snackContexts.add(context);
          return Text([title, ...warnings].join('\n'));
        },
      ),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          if (undoing || !deletion.changes.canUndo) return;
          undoing = true;
          final result = await undoAndLog(
            deletion.changes,
            writer.editor!,
            writer.changeLog,
            create: writer.create,
          );
          final stayed = [
            for (final MapEntry(key: path, value: outcome) in result.entries)
              if (outcome == UndoOutcome.changedSince ||
                  outcome == UndoOutcome.otherFolder ||
                  outcome == UndoOutcome.failed)
                deletion.changes.first(path).title,
          ];
          if (!messenger.mounted) return;
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                persist: false,
                content: Text(
                  stayed.isEmpty
                      ? 'Undone.'
                      : 'Undone. Left unchanged: ${stayed.join(', ')}.',
                ),
              ),
            );
        },
      ),
    ),
  );
  // Undo and swipe gestures inside the snack bar remain available.
  void dismissOnAction(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    for (final context in snackContexts.where((c) => c.mounted)) {
      var inside = false;
      context.visitAncestorElements((element) {
        if (element.widget is! SnackBar) return true;
        final box = element.findRenderObject();
        inside =
            box is RenderBox &&
            box.attached &&
            (box.localToGlobal(Offset.zero) & box.size).contains(
              event.position,
            );
        return false;
      });
      if (inside) return;
    }
    if (messenger.mounted) messenger.hideCurrentSnackBar();
  }

  bool dismissOnKey(KeyEvent event) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (event is KeyDownEvent &&
        messenger.mounted &&
        focus?.findAncestorWidgetOfExactType<SnackBar>() == null) {
      messenger.hideCurrentSnackBar();
    }
    return false;
  }

  GestureBinding.instance.pointerRouter.addGlobalRoute(dismissOnAction);
  HardwareKeyboard.instance.addHandler(dismissOnKey);
  controller.closed.then((_) {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(dismissOnAction);
    HardwareKeyboard.instance.removeHandler(dismissOnKey);
  });
}
