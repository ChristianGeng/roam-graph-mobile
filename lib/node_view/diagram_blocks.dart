/// What the diagrams drawn on the device share, whatever draws them:
/// Mermaid (#49, decision 41) and PlantUML (#283, decision 151). Finding
/// the blocks to draw, the link that stands for a drawing, the error line,
/// the label below a drawing and the page that shows one alone.
library;

import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

/// A `#+RESULTS:` keyword, also with a hash (`#+RESULTS[hash]:`), as Org's
/// `org-babel-result-regexp` matches it.
final _resultsKey = RegExp(r'^#\+results(?:\[[^\]]*\])?:$', caseSensitive: false);

/// [document] with the paragraph [drawing] makes after each source block
/// of [language] that has no result image, as Emacs shows the result below
/// the block. [showsImage] tells whether the node view shows an image for
/// a link's location; [drawing] gets the block's source ([blockSource]).
///
/// A block's result is the `#+RESULTS:` keyword right after it (only blank
/// lines between) and the paragraph after that, where Org Babel writes the
/// link to the block's `:file`. A block whose result paragraph has a link
/// the node view shows as an image (one without a description, whose image
/// is in the folder) is left alone: that image is what Emacs drew on the
/// laptop. Every other block of [language] (no `:file`, never run, or its
/// image is not in the folder) gets a drawing right after it.
///
/// The language is compared as written, as Emacs picks the Babel backend.
OrgDocument withBlockDrawings(
  OrgDocument document, {
  required String language,
  required bool Function(String location) showsImage,
  required OrgParagraph Function(String source) drawing,
}) {
  var changed = false;
  final edited = document.edit().visit((location) {
    final node = location.node;
    if (node is OrgSrcBlock &&
        node.language == language &&
        !_hasResultImage(location, showsImage)) {
      changed = true;
      return (true, location.insertRight(drawing(blockSource(node))));
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

/// The text of a source block as Org Babel hands it to the program: the
/// body without Org's comma escapes (`,*` and `,#+` at a line's start).
String blockSource(OrgSrcBlock block) => block.body
    .toMarkup()
    .replaceAllMapped(RegExp(r'^([ \t]*,*),(?=\*|#\+)', multiLine: true),
        (match) => match.group(1)!);

/// A paragraph with one link that stands for the drawing of [source]: the
/// source is kept in [sources] by the link itself, so the node view's
/// `loadImage` can tell an added link from one the note writes.
/// `org_flutter` hands only links whose [location] looks like an image to
/// `loadImage`; the location itself is not read.
OrgParagraph drawingLink(
    String location, Expando<String> sources, String source) {
  final paragraph = OrgDocument.parse('[[$location]]\n')
      .content!
      .children
      .single as OrgParagraph;
  paragraph.visit<OrgLink>((link) {
    sources[link] = source;
    return false;
  });
  return paragraph;
}

/// One line in place of a drawing that failed: an error icon and [text],
/// cut at the end of the line.
class DiagramError extends StatelessWidget {
  const DiagramError(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline,
              size: 18, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );
}

/// A drawing below its source block, never wider than the text column,
/// with a label that says it was drawn here: it is not the laptop's
/// result. Tapping it calls [onTap].
class DrawnDiagram extends StatelessWidget {
  const DrawnDiagram({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onTap,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: child,
            ),
          ),
          Text('Drawn on the device',
              style: Theme.of(context).textTheme.labelSmall),
        ],
      );
}

/// A drawing alone on its page, under [title], with pinch zoom; [child]
/// is null when there is nothing to show. Back returns to the node.
class DiagramPage extends StatelessWidget {
  const DiagramPage({super.key, required this.title, required this.child});

  final String title;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: switch (child) {
          null => const SizedBox.shrink(),
          final child => InteractiveViewer(
              maxScale: 8,
              // Drawn anew at each zoom, so it stays sharp.
              child: Center(
                child: FittedBox(fit: BoxFit.contain, child: child),
              ),
            ),
        },
      );
}
