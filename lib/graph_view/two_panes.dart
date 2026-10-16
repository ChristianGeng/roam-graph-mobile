import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../settings/view_settings.dart';

/// The graph and the note side by side on a tablet in landscape (#16, #69),
/// with a divider to drag and a button that folds the graph into a strip.
/// The share and the folded state are kept in the view settings (#63).
class TwoPanes extends StatefulWidget {
  const TwoPanes({super.key, required this.graph, required this.note});

  final Widget graph;
  final Widget note;

  /// The narrowest the graph and the note get while both show.
  static const minGraph = 240.0;
  static const minNote = 320.0;

  /// The width of the folded graph.
  static const strip = 48.0;

  /// The divider's touch area: wide for a finger, though its line is thin.
  static const handle = 24.0;

  @override
  State<TwoPanes> createState() => _TwoPanesState();
}

class _TwoPanesState extends State<TwoPanes> {
  /// The graph's width while the divider is dragged, not limited yet;
  /// null otherwise.
  double? _dragging;

  /// Where the finger touched the divider, and the graph's width then: the
  /// divider follows the finger from there, the touch slop included.
  double _downX = 0;
  double _downWidth = 0;

  /// What a drag or a button chose, until the settings have it.
  ViewSettings? _pending;

  Future<void> _save(ViewSettings settings) async {
    setState(() => _pending = settings);
    try {
      await ViewSettingsScope.change(context, settings);
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the layout: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _pending ?? ViewSettingsScope.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        // The widest the graph gets, so the note keeps its minimum.
        final widest = max(
          TwoPanes.strip,
          width - TwoPanes.minNote - TwoPanes.handle,
        );
        final narrowest = min(TwoPanes.minGraph, widest);
        double shown(double share) =>
            (share * width).clamp(narrowest, widest).toDouble();
        final dragging = _dragging;
        final collapsed = settings.graphCollapsed && dragging == null;
        final graphWidth = collapsed
            ? TwoPanes.strip
            : dragging != null
            ? dragging.clamp(TwoPanes.strip, widest).toDouble()
            : shown(settings.graphShare);

        void end() {
          final raw = _dragging;
          if (raw == null) return;
          setState(() => _dragging = null);
          // Dragged all the way to the left: fold the graph, keeping its share.
          if (raw < narrowest / 2) {
            _save(settings.copyWith(graphCollapsed: true));
          } else {
            _save(
              settings.copyWith(
                graphShare: shown(raw / width) / width,
                graphCollapsed: false,
              ),
            );
          }
        }

        return Row(
          children: [
            SizedBox(
              width: graphWidth,
              child: collapsed
                  ? Material(
                      key: const ValueKey('graph-strip'),
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: Column(
                        children: [
                          IconButton(
                            tooltip: 'Show graph',
                            icon: const Icon(Icons.chevron_right),
                            onPressed: () =>
                                _save(settings.copyWith(graphCollapsed: false)),
                          ),
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Center(
                                child: Text(
                                  'Graph',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : Stack(
                      children: [
                        Positioned.fill(child: widget.graph),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: IconButton.filledTonal(
                            tooltip: 'Fold graph',
                            icon: const Icon(Icons.chevron_left),
                            onPressed: () =>
                                _save(settings.copyWith(graphCollapsed: true)),
                          ),
                        ),
                      ],
                    ),
            ),
            _Divider(
              onDown: (x) {
                _downX = x;
                _downWidth = graphWidth;
              },
              onStart: () => setState(() => _dragging = _downWidth),
              onUpdate: (x) =>
                  setState(() => _dragging = _downWidth + x - _downX),
              onEnd: end,
              // The default split, unfolded.
              onDoubleTap: () => _save(
                settings.copyWith(
                  graphShare: ViewSettings.defaultGraphShare,
                  graphCollapsed: false,
                ),
              ),
            ),
            Expanded(child: widget.note),
          ],
        );
      },
    );
  }
}

/// The line between the panes: thin, with a drag handle, in a touch area
/// [TwoPanes.handle] wide.
class _Divider extends StatelessWidget {
  const _Divider({
    required this.onDown,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onDoubleTap,
  });

  /// Where the finger touched, and where it is now: global x positions.
  final void Function(double x) onDown;
  final VoidCallback onStart;
  final void Function(double x) onUpdate;
  final VoidCallback onEnd;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: const ValueKey('pane-divider'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragDown: (details) => onDown(details.globalPosition.dx),
        onHorizontalDragStart: (_) => onStart(),
        onHorizontalDragUpdate: (details) =>
            onUpdate(details.globalPosition.dx),
        onHorizontalDragEnd: (_) => onEnd(),
        onHorizontalDragCancel: onEnd,
        onDoubleTap: onDoubleTap,
        child: SizedBox(
          width: TwoPanes.handle,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: colors.outlineVariant,
              ),
              Container(
                width: 8,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.outline,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
