/// The widgets of the node view's quick edits (#150): the actions a slide
/// on a heading reveals, the list of TODO states, and the folding kept
/// over an edit.
library;

import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../edit/org_toggles.dart';

/// Sets each section of [tree] to its state in [states] (in the order of
/// [sectionsOf]) once, before the first build, so a note read again after a
/// quick edit keeps the sections open that were open. Below an
/// [OrgController]; without [states] it does nothing.
class KeepFolding extends StatefulWidget {
  const KeepFolding({
    super.key,
    required this.tree,
    required this.states,
    required this.child,
  });

  final OrgTree tree;
  final List<OrgVisibilityState>? states;
  final Widget child;

  @override
  State<KeepFolding> createState() => _KeepFoldingState();
}

class _KeepFoldingState extends State<KeepFolding> {
  var _applied = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_applied) return;
    _applied = true;
    final states = widget.states;
    if (states == null) return;
    final controller = OrgController.of(context);
    for (final (i, section) in sectionsOf(widget.tree).indexed) {
      if (i >= states.length) break;
      controller.setVisibilityOf(section, (_) => states[i]);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One action revealed by sliding a heading: an icon over a label.
class TodoSlideAction extends StatelessWidget {
  const TodoSlideAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: scheme.secondaryContainer,
        child: InkWell(
          onTap: onPressed,
          // A heading may be one short line, so icon and label sit side
          // by side, scaled down if they do not fit.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: scheme.onSecondaryContainer),
                    const SizedBox(width: 4),
                    Text(label,
                        style: TextStyle(color: scheme.onSecondaryContainer)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A TODO state chosen in the list; [keyword] null is "no state".
typedef TodoChoice = ({String? keyword});

/// Shows the TODO states of a note, [current] marked, and returns the one
/// chosen, or null when the list was closed.
Future<TodoChoice?> chooseTodoState(
  BuildContext context, {
  required List<OrgTodoStates> states,
  required String? current,
}) =>
    showModalBottomSheet<TodoChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        Widget tile(String? keyword) => ListTile(
              key: ValueKey('todo-state-${keyword ?? '-'}'),
              title: Text(keyword ?? 'No state'),
              trailing: keyword == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, (keyword: keyword)),
            );
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              tile(null),
              for (final keyword in allKeywords(states)) tile(keyword),
            ],
          ),
        );
      },
    );
