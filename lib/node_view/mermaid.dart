/// Mermaid diagrams drawn on the device (#49, decision 41), for mermaid
/// blocks that have no result image. What PlantUML (#283) shares with it
/// is in `diagram_blocks.dart`.
library;

import 'package:material_ui/material_ui.dart';
import 'package:mermaid_core/mermaid_core.dart' as core;
import 'package:mermaid_flutter/mermaid_flutter.dart';
import 'package:org_flutter/org_flutter.dart';

import 'diagram_blocks.dart';

/// The mermaid source of each link that [withMermaidDrawings] added, by the
/// link itself: the node view's `loadImage` shows a drawing for these.
final _drawingSource = Expando<String>('mermaid source');

/// The location of the added links. The location itself is not read: a
/// link the note writes with it stays a link ([_drawingSource]).
const _drawingLocation = 'mermaid-drawing.png';

/// [document] with a drawing after each mermaid source block that has no
/// result image, as Emacs shows the result below the block. [showsImage]
/// tells whether the node view shows an image for a link's location.
///
/// A block's result is the `#+RESULTS:` keyword right after it (only blank
/// lines between) and the paragraph after that, where `ob-mermaid` writes
/// the link to its `:file`. A block whose result paragraph has a link the
/// node view shows as an image (one without a description, whose image is
/// in the folder) is left alone: that image is what `mmdc`
/// drew on the laptop. Every other mermaid block (no `:file`, never run,
/// or its image is not in the folder) gets a drawing right after it.
///
/// The language is compared as written: Emacs runs only `mermaid` blocks
/// with `ob-mermaid`.
OrgDocument withMermaidDrawings(
  OrgDocument document, {
  required bool Function(String location) showsImage,
}) =>
    withBlockDrawings(
      document,
      language: 'mermaid',
      showsImage: showsImage,
      drawing: (source) =>
          drawingLink(_drawingLocation, _drawingSource, source),
    );

/// The text of a mermaid block as `ob-mermaid` hands it to `mmdc`: the
/// body without Org's comma escapes (`,*` and `,#+` at a line's start).
String mermaidSource(OrgSrcBlock block) => blockSource(block);

/// The drawing for [link], if [withMermaidDrawings] added it; else null.
Widget? loadMermaidDrawing(OrgLink link) => switch (_drawingSource[link]) {
      final source? => MermaidDrawing(source),
      null => null,
    };

/// A drawn diagram, or why it could not be drawn.
typedef MermaidDrawn = ({core.RenderScene? scene, Object? error});

/// Drawings by source and theme, so scrolling and showing a note again do
/// not parse and lay out its diagrams again. The oldest are dropped beyond
/// [_maxDrawn].
final _drawn = <(String, bool), MermaidDrawn>{};
const _maxDrawn = 32;

/// [source] laid out with mermaid's `dark` theme if [dark], else its
/// `default` theme. A theme the source sets with `%%{init: ...}%%` comes
/// first, as in mermaid.
MermaidDrawn drawMermaid(String source, {required bool dark}) {
  final key = (source, dark);
  if (_drawn.remove(key) case final drawn?) return _drawn[key] = drawn;
  MermaidDrawn drawn;
  try {
    drawn = (
      scene: core.Mermaid(
        measurer: const FlutterTextMeasurer(),
        theme: dark ? core.MermaidTheme.darkTheme : core.MermaidTheme.defaultTheme,
      ).render(source),
      error: null,
    );
  } on Object catch (error) {
    drawn = (scene: null, error: error);
  }
  _drawn[key] = drawn;
  if (_drawn.length > _maxDrawn) _drawn.remove(_drawn.keys.first);
  return drawn;
}

/// The theme a mermaid source sets in its `%%{init: ...}%%` directive.
String? _ownTheme(String source) => RegExp(
        r'''%%\{\s*init\s*:.*?['"]?theme['"]?\s*:\s*['"]([\w-]+)['"]''',
        dotAll: true)
    .firstMatch(source)
    ?.group(1);

/// The scene of a drawing at its own size, on a white background when the
/// page is dark and the source sets a light theme of its own, so its dark
/// lines can be read, as SVGs are shown (#47).
Widget _painted(BuildContext context, String source, core.RenderScene scene) {
  final painted = SizedBox(
    width: scene.size.width,
    height: scene.size.height,
    child: CustomPaint(painter: ScenePainter(scene)),
  );
  final own = _ownTheme(source);
  return Theme.of(context).brightness == Brightness.dark &&
          own != null &&
          own != 'dark'
      ? ColoredBox(color: Colors.white, child: painted)
      : painted;
}

/// A mermaid diagram drawn on the device, below its source block, never
/// wider than the text column, with a label that says so: it is not the
/// laptop's result. Tapping it shows it alone, with zoom
/// ([MermaidPage]). A source that cannot be drawn shows one line with the
/// error.
class MermaidDrawing extends StatelessWidget {
  const MermaidDrawing(this.source, {super.key});

  final String source;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final drawn = drawMermaid(source, dark: dark);
    final scene = drawn.scene;
    if (scene == null) {
      return DiagramError(
          'Mermaid cannot draw this: ${_errorLine(drawn.error!)}');
    }
    return DrawnDiagram(
      onTap: () => MermaidPage.open(context, source),
      child: _painted(context, source, scene),
    );
  }
}

/// The first line of [error]'s message.
String _errorLine(Object error) {
  final message = error is core.MermaidParseException
      ? '${error.message}${error.line == null ? '' : ' (line ${error.line})'}'
      : '$error';
  return message.split('\n').first;
}

/// A drawn diagram alone on its page, with pinch zoom. Back returns to the
/// node.
class MermaidPage extends StatelessWidget {
  const MermaidPage({super.key, required this.source});

  final String source;

  static Future<void> open(BuildContext context, String source) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => MermaidPage(source: source),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scene = drawMermaid(source,
            dark: Theme.of(context).brightness == Brightness.dark)
        .scene;
    return DiagramPage(
      title: 'Mermaid diagram',
      child: scene == null ? null : _painted(context, source, scene),
    );
  }
}
