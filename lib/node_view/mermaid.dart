/// Mermaid diagrams drawn on the device (#49, decision 41), for mermaid
/// blocks that have no result image.
library;

import 'package:material_ui/material_ui.dart';
import 'package:mermaid_core/mermaid_core.dart' as core;
import 'package:mermaid_flutter/mermaid_flutter.dart';
import 'package:org_flutter/org_flutter.dart';

/// The mermaid source of each link that [withMermaidDrawings] added, by the
/// link itself: the node view's `loadImage` shows a drawing for these.
final _drawingSource = Expando<String>('mermaid source');

/// The location of the added links. `org_flutter` hands only links whose
/// location looks like an image to `loadImage`; the location itself is not
/// read: a link the note writes with it stays a link ([_drawingSource]).
const _drawingLocation = 'mermaid-drawing.png';

/// A `#+RESULTS:` keyword, also with a hash (`#+RESULTS[hash]:`), as Org's
/// `org-babel-result-regexp` matches it.
final _resultsKey = RegExp(r'^#\+results(?:\[[^\]]*\])?:$', caseSensitive: false);

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
}) {
  var changed = false;
  final edited = document.edit().visit((location) {
    final node = location.node;
    if (node is OrgSrcBlock &&
        node.language == 'mermaid' &&
        !_hasResultImage(location, showsImage)) {
      changed = true;
      return (true, location.insertRight(_drawing(mermaidSource(node))));
    }
    return (true, null);
  });
  return changed ? edited.commit<OrgDocument>() : document;
}

bool _hasResultImage(OrgZipper block, bool Function(String) showsImage) {
  if (!block.canGoRight()) return false;
  final keyword = block.goRight();
  final meta = keyword.node;
  if (meta is! OrgMeta || !_resultsKey.hasMatch(meta.key)) return false;
  if (!keyword.canGoRight()) return false;
  final paragraph = keyword.goRight().node;
  if (paragraph is! OrgParagraph) return false;
  var shown = false;
  paragraph.visit<OrgLink>((link) {
    // As org_flutter: only a link without a description is shown as an
    // image; any such link in the paragraph counts.
    shown = (link is! OrgBracketLink || link.description == null) &&
        showsImage(link.location);
    return !shown;
  });
  return shown;
}

/// The text of a mermaid block as `ob-mermaid` hands it to `mmdc`: the
/// body without Org's comma escapes (`,*` and `,#+` at a line's start).
String mermaidSource(OrgSrcBlock block) => block.body
    .toMarkup()
    .replaceAllMapped(RegExp(r'^([ \t]*,*),(?=\*|#\+)', multiLine: true),
        (match) => match.group(1)!);

/// A paragraph with one link that stands for the drawing of [source].
OrgParagraph _drawing(String source) {
  final paragraph = OrgDocument.parse('[[$_drawingLocation]]\n')
      .content!
      .children
      .single as OrgParagraph;
  paragraph.visit<OrgLink>((link) {
    _drawingSource[link] = source;
    return false;
  });
  return paragraph;
}

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
    final textTheme = Theme.of(context).textTheme;
    final scene = drawn.scene;
    if (scene == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline,
              size: 18, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'Mermaid cannot draw this: ${_errorLine(drawn.error!)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall,
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => MermaidPage.open(context, source),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: _painted(context, source, scene),
          ),
        ),
        Text('Drawn on the device', style: textTheme.labelSmall),
      ],
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
    return Scaffold(
      appBar: AppBar(title: const Text('Mermaid diagram')),
      body: scene == null
          ? const SizedBox.shrink()
          : InteractiveViewer(
              maxScale: 8,
              // Drawn anew at each zoom, so it stays sharp.
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: _painted(context, source, scene),
                ),
              ),
            ),
    );
  }
}
