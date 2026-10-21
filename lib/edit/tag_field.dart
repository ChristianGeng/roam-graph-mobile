import 'package:material_ui/material_ui.dart';

import '../graph/roam_graph.dart';
import 'node_meta.dart' show validTag;

/// A tag of the graph and the number of notes (files) that have it.
typedef TagCount = ({String tag, int notes});

/// The tags of [graph], the most used first, each with the number of notes
/// (files) where a node has it; equal counts in alphabetical order. Tags
/// are compared as written, as Org does (decision 42).
List<TagCount> tagCounts(RoamGraph? graph) {
  if (graph == null) return const [];
  final files = <String, Set<String>>{};
  for (final node in graph.nodes.values) {
    for (final tag in node.tags) {
      (files[tag] ??= {}).add(node.file);
    }
  }
  return [
    for (final MapEntry(:key, :value) in files.entries)
      (tag: key, notes: value.length),
  ]..sort((a, b) {
      final byCount = b.notes.compareTo(a.notes);
      return byCount != 0 ? byCount : a.tag.compareTo(b.tag);
    });
}

/// The tags of a [TagField]: the chosen ones, in their order, and the text
/// typed but not added yet.
class TagFieldController extends ChangeNotifier {
  TagFieldController([List<String> tags = const []]) : _chosen = [...tags] {
    text.addListener(notifyListeners);
  }

  final List<String> _chosen;

  /// What is typed in the field; never holds a separator.
  final text = TextEditingController();

  /// The tags shown as chips.
  List<String> get chosen => List.unmodifiable(_chosen);

  /// The tags to save: the chosen ones, then the typed text, if it is not
  /// one of them.
  List<String> get tags {
    final typed = text.text.trim();
    return [..._chosen, if (typed.isNotEmpty && !_chosen.contains(typed)) typed];
  }

  /// Adds [tag] at the end, unless it is empty or chosen already.
  void add(String tag) {
    if (tag.isEmpty || _chosen.contains(tag)) return;
    _chosen.add(tag);
    notifyListeners();
  }

  void remove(String tag) {
    if (_chosen.remove(tag)) notifyListeners();
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }
}

/// One tag field (#140), as `org-roam-tag-add` with completion: the chosen
/// tags as chips, and below them the graph's tags to choose from, the most
/// used first. Typing filters them; space, comma, colon or Enter adds the
/// typed text. Characters Org does not read in a tag are refused.
class TagField extends StatefulWidget {
  const TagField({
    super.key,
    required this.controller,
    this.known = const [],
    this.label = 'Tags',
    this.helperText,
  });

  final TagFieldController controller;

  /// The graph's tags, from [tagCounts].
  final List<TagCount> known;

  final String label;
  final String? helperText;

  @override
  State<TagField> createState() => _TagFieldState();
}

class _TagFieldState extends State<TagField> {
  static final _separator = RegExp(r'[\s,:]');

  /// The suggestions shown before "All tags" is tapped.
  static const _first = 20;

  /// Why the last characters typed were refused.
  String? _refused;
  bool _all = false;

  TagFieldController get _c => widget.controller;

  void _typed(String value) {
    final refused = <String>{};
    final kept = StringBuffer();
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (_separator.hasMatch(char) || validTag.hasMatch(char)) {
        kept.write(char);
      } else {
        refused.add(char);
      }
    }
    final parts = kept.toString().split(_separator);
    for (final part in parts.take(parts.length - 1)) {
      _c.add(part);
    }
    final rest = parts.last;
    if (rest != value) {
      _c.text.value = TextEditingValue(
          text: rest, selection: TextSelection.collapsed(offset: rest.length));
    }
    setState(() => _refused = refused.isEmpty
        ? null
        : '${refused.map((c) => '"$c"').join(' ')} cannot be in a tag: only '
            'letters, digits and _@#% can.');
  }

  void _addTyped() {
    _c.add(_c.text.text.trim());
    _c.text.clear();
  }

  void _choose(String tag) {
    _c.add(tag);
    _c.text.clear();
    setState(() => _refused = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final chosen = _c.chosen;
        final typed = _c.text.text;
        final query = typed.toLowerCase();
        final matching = [
          for (final known in widget.known)
            if (!chosen.contains(known.tag) &&
                known.tag.toLowerCase().contains(query))
              known,
        ];
        final shown = _all ? matching : matching.take(_first).toList();
        final isNew = typed.isNotEmpty &&
            !chosen.contains(typed) &&
            !widget.known.any((known) => known.tag == typed);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (chosen.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final tag in chosen)
                      InputChip(
                        key: ValueKey('tag-chosen-$tag'),
                        label: Text(tag),
                        onDeleted: () => _c.remove(tag),
                        deleteButtonTooltipMessage: 'Remove $tag',
                      ),
                  ],
                ),
              ),
            TextField(
              controller: _c.text,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: 'Type a tag, or tap one below',
                helperText: widget.helperText,
                helperMaxLines: 4,
                errorText: _refused,
                errorMaxLines: 3,
              ),
              onChanged: _typed,
              onSubmitted: (_) => _addTyped(),
              // Enter adds the tag and keeps the focus for the next one.
              onEditingComplete: () {},
            ),
            if (isNew || shown.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (isNew)
                      ActionChip(
                        key: const ValueKey('tag-new'),
                        avatar: const Icon(Icons.add),
                        label: Text('New tag: $typed'),
                        onPressed: _addTyped,
                      ),
                    for (final known in shown)
                      ActionChip(
                        key: ValueKey('tag-known-${known.tag}'),
                        label: Text('${known.tag} (${known.notes})'),
                        onPressed: () => _choose(known.tag),
                      ),
                  ],
                ),
              ),
            if (shown.length < matching.length)
              TextButton(
                onPressed: () => setState(() => _all = true),
                child: Text('All ${matching.length} tags'),
              ),
          ],
        );
      },
    );
  }
}
