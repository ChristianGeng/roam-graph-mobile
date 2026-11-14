/// PlantUML diagrams drawn on the device with `puml_canvas` (#283,
/// decision 151), for plantuml blocks that have no result image. Works as
/// the Mermaid drawings do (`mermaid.dart`), with what they share in
/// `diagram_blocks.dart`.
///
/// `puml_canvas` is young, so everything that uses it is in this file:
/// to update or remove it, change this file, the two calls in
/// `node_screen.dart` and the line in `pubspec.yaml`.
library;

import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:puml_canvas/puml_canvas.dart' as puml;

import 'diagram_blocks.dart';

/// The plantuml source of each link that [withPlantumlDrawings] added, by
/// the link itself: the node view's `loadImage` shows a drawing for these.
final _drawingSource = Expando<String>('plantuml source');

/// The location of the added links. The location itself is not read: a
/// link the note writes with it stays a link ([_drawingSource]).
const _drawingLocation = 'plantuml-drawing.png';

/// [document] with a drawing after each plantuml source block that has no
/// result image, as Emacs shows the result below the block. [showsImage]
/// tells whether the node view shows an image for a link's location.
///
/// A block whose `#+RESULTS:` paragraph has a link the node view shows as
/// an image is left alone: that image is what PlantUML drew on the laptop
/// (`ob-plantuml` with `:file`), and it is exact. Every other plantuml
/// block (no `:file`, never run, or its image is not in the folder) gets a
/// drawing right after it ([withBlockDrawings]).
///
/// The language is compared as written: Emacs runs only `plantuml` blocks
/// with `ob-plantuml`.
OrgDocument withPlantumlDrawings(
  OrgDocument document, {
  required bool Function(String location) showsImage,
}) =>
    withBlockDrawings(
      document,
      language: 'plantuml',
      showsImage: showsImage,
      drawing: (source) =>
          drawingLink(_drawingLocation, _drawingSource, source),
    );

/// The drawing for [link], if [withPlantumlDrawings] added it; else null.
Widget? loadPlantumlDrawing(OrgLink link) => switch (_drawingSource[link]) {
      final source? => PlantumlDrawing(source),
      null => null,
    };

/// Whether a source starts with its own `@start...` line, as
/// `org-babel-plantuml-make-body` checks it (case is ignored). Blank space
/// before it is allowed here: it would only make the drawing fail.
final _ownStart = RegExp(r'^\s*@start', caseSensitive: false);

/// [source] as PlantUML gets it from `ob-plantuml`: a body without its own
/// `@start...` line is put between `@startuml` and `@enduml`.
String plantumlSource(String source) => _ownStart.hasMatch(source)
    ? source
    : '@startuml\n$source${source.endsWith('\n') ? '' : '\n'}@enduml\n';

/// A drawn diagram, or why it could not be drawn.
typedef PlantumlDrawn = ({puml.Scene? scene, Object? error});

/// Drawings by source, so scrolling and showing a note again do not parse
/// and lay out its diagrams again. Unlike Mermaid's, a PlantUML drawing is
/// the same in both themes (the dark theme puts it on a light card), so
/// the theme is not part of the key. The oldest are dropped beyond
/// [_maxDrawn].
final _drawn = <String, PlantumlDrawn>{};
const _maxDrawn = 32;

/// [source] parsed and laid out by `puml_canvas`, with `@startuml` and
/// `@enduml` added if it has no `@start...` line ([plantumlSource]). Any
/// error is caught and returned: a source that cannot be drawn never
/// stops the node view.
PlantumlDrawn drawPlantuml(String source) {
  if (_drawn.remove(source) case final drawn?) return _drawn[source] = drawn;
  PlantumlDrawn drawn;
  if (source.length > maxPlantumlSource) {
    // Parsing and layout run while the note is shown; a huge source
    // would stop the view for too long.
    drawn = (
      scene: null,
      error: 'the diagram is too large to draw on the device '
          '(more than $maxPlantumlSource characters)',
    );
  } else {
    drawn = _parsedAndLaidOut(source);
  }
  _drawn[source] = drawn;
  if (_drawn.length > _maxDrawn) _drawn.remove(_drawn.keys.first);
  return drawn;
}

/// The longest source drawn on the device. Real diagrams are far shorter;
/// a longer one shows an error line, so it cannot stop the node view.
const maxPlantumlSource = 20000;

/// The longest text after the preprocessor has expanded `!define` and
/// other macros: a short source can expand to far more. The expansion
/// itself is bounded only inside `puml_canvas`.
const maxPlantumlExpanded = 100000;

PlantumlDrawn _parsedAndLaidOut(String source) {
  PlantumlDrawn drawn;
  final wrapped = plantumlSource(source);
  String? text;
  try {
    text = puml.Preprocessor().preprocess(wrapped);
    if (text.length > maxPlantumlExpanded) {
      return (
        scene: null,
        error: 'the diagram is too large to draw on the device '
            '(more than $maxPlantumlExpanded characters after its macros '
            'are expanded)',
      );
    }
    final diagram = puml.Parser().parse(puml.Lexer().tokenize(text));
    final scene = const puml.AutoLayout()
        .layout(diagram, const puml.FlutterTextMeasurer());
    drawn = scene.size.isEmpty
        ? (scene: null, error: 'the diagram is empty')
        : (scene: scene, error: null);
  } on Object catch (error) {
    // The lexer and the parser count lines in the preprocessed text. When
    // the preprocessor removed or added lines (directives, macros), those
    // numbers are not lines of the block, so the message goes without one.
    final shifted = text != null &&
        '\n'.allMatches(text).length != '\n'.allMatches(wrapped).length;
    drawn = switch (error) {
      puml.LexerException(:final message) when shifted => (
          scene: null,
          error: message,
        ),
      puml.ParserException(:final message) when shifted => (
          scene: null,
          error: message,
        ),
      _ => (scene: null, error: error),
    };
  }
  return drawn;
}

/// Paints a `puml_canvas` scene. Public so tests can find the drawings.
class PlantumlPainter extends CustomPainter {
  const PlantumlPainter(this.scene);

  final puml.Scene scene;

  @override
  void paint(Canvas canvas, Size size) =>
      const puml.Renderer().render(canvas, scene);

  @override
  bool shouldRepaint(PlantumlPainter oldDelegate) =>
      !identical(oldDelegate.scene, scene);
}

/// The background of the card a drawing is on in the dark theme.
const plantumlCardColor = Colors.white;

/// The scene of a drawing at its own size. `puml_canvas` has no dark
/// theme: its lines, arrows and loose text are always black. So in the
/// dark theme the drawing is on a light card with rounded corners and a
/// margin, where it can be read, as a light SVG is.
Widget _painted(BuildContext context, puml.Scene scene) {
  final painted = SizedBox(
    width: scene.size.width,
    height: scene.size.height,
    child: CustomPaint(painter: PlantumlPainter(scene)),
  );
  return Theme.of(context).brightness == Brightness.dark
      ? Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: plantumlCardColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: painted,
        )
      : painted;
}

/// A PlantUML diagram drawn on the device, below its source block, never
/// wider than the text column, with a label that says so: it is not the
/// laptop's result. Tapping it shows it alone, with zoom
/// ([PlantumlPage]). A source that cannot be drawn shows one line with the
/// error.
class PlantumlDrawing extends StatelessWidget {
  const PlantumlDrawing(this.source, {super.key});

  final String source;

  @override
  Widget build(BuildContext context) {
    final drawn = drawPlantuml(source);
    final scene = drawn.scene;
    if (scene == null) {
      return DiagramError(
          'PlantUML cannot draw this: ${_errorLine(source, drawn.error!)}');
    }
    return DrawnDiagram(
      onTap: () => PlantumlPage.open(context, source),
      child: _painted(context, scene),
    );
  }
}

/// The error line shown for [source], or null if it can be drawn.
@visibleForTesting
String? errorLineOf(String source) => switch (drawPlantuml(source).error) {
      final error? => _errorLine(source, error),
      null => null,
    };

/// The first line of [error]'s message. When `puml_canvas` gives a line
/// (its parser, lexer and preprocessor do), it is counted in the block's
/// own [source], without an added `@startuml`. Other errors have none, and
/// neither have lexer and parser errors after the preprocessor removed or
/// added lines ([_parsedAndLaidOut] passes those on as plain messages).
String _errorLine(String source, Object error) {
  final added = _ownStart.hasMatch(source) ? 0 : 1;
  String at(int line) => ' (line ${line - added < 1 ? 1 : line - added})';
  final message = switch (error) {
    puml.ParserException() => '${error.message}${at(error.line)}',
    puml.LexerException() => '${error.message}${at(error.line)}',
    puml.PreprocessorException() => '${error.message}${at(error.line)}',
    _ => '$error',
  };
  return message.split('\n').first;
}

/// A drawn PlantUML diagram alone on its page, with pinch zoom. Back
/// returns to the node.
class PlantumlPage extends StatelessWidget {
  const PlantumlPage({super.key, required this.source});

  final String source;

  static Future<void> open(BuildContext context, String source) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => PlantumlPage(source: source),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scene = drawPlantuml(source).scene;
    return DiagramPage(
      title: 'PlantUML diagram',
      child: scene == null ? null : _painted(context, scene),
    );
  }
}
