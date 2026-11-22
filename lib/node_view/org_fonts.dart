/// Code in a monospace font (#238, #239), as Emacs and Org's export show
/// it: inline ~code~ and =verbatim=, fixed-width lines, source, example
/// and export blocks, and inline source blocks. org_flutter's own themes
/// leave the font alone, because its main user, Orgro, shows the whole
/// document in a monospace font.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:org_flutter/org_flutter.dart';

import 'drawn_latex.dart';

/// org_flutter's [OrgText] with [MonospaceOrgThemes]: [OrgText] makes
/// its own themes and takes none. The rest is as [OrgText] builds it:
/// markup hidden, no padding, shrink-wrapped. LaTeX formulas are drawn
/// with katex, as in a note (#308).
class MonospaceOrgText extends StatefulWidget {
  const MonospaceOrgText(this.text, {this.onLinkTap, super.key});

  final String text;
  final void Function(OrgLink)? onLinkTap;

  @override
  State<MonospaceOrgText> createState() => _MonospaceOrgTextState();
}

class _MonospaceOrgTextState extends State<MonospaceOrgText> {
  late OrgDocument _doc = OrgDocument.parse(widget.text);

  @override
  void didUpdateWidget(covariant MonospaceOrgText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _doc = OrgDocument.parse(widget.text);
  }

  @override
  Widget build(BuildContext context) => OrgController(
    root: _doc,
    settings: OrgSettings.hideMarkup,
    child: OrgRootWidget(
      onLinkTap: widget.onLinkTap,
      loadLatexInline: loadLatexInline,
      loadLatexBlock: loadLatexBlock,
      lightTheme: MonospaceOrgThemes.lightTight,
      darkTheme: MonospaceOrgThemes.darkTight,
      child: OrgDocumentWidget(_doc, shrinkWrap: true, safeArea: false),
    ),
  );
}

/// The platform's monospace font: Menlo on macOS, Consolas on Windows,
/// the fontconfig alias `monospace` on Linux and Android. No font file is
/// bundled.
String get monospaceFamily => switch (defaultTargetPlatform) {
  TargetPlatform.macOS || TargetPlatform.iOS => 'Menlo',
  TargetPlatform.windows => 'Consolas',
  _ => 'monospace',
};

/// Tried in order when [monospaceFamily] is missing.
const monospaceFallback = [
  'Menlo',
  'Consolas',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'Courier New',
  'monospace',
];

/// The text style that puts code in [monospaceFamily]. It sets only the
/// font; the size is the size of the text around, and org_flutter's
/// colours stay.
TextStyle get monospaceTextStyle => TextStyle(
  fontFamily: monospaceFamily,
  fontFamilyFallback: monospaceFallback,
);

/// [base] with the monospace font for org_flutter's three code styles:
/// `codeTextStyle` (~code~ and `: ` fixed-width lines), `verbatimTextStyle`
/// (=verbatim=) and `blockTextStyle` (source, example and export blocks,
/// inline source blocks). Every colour of [base] stays; quote and verse
/// blocks and the rest of the text keep their font.
OrgThemeData withMonospaceCode(OrgThemeData base) => base.copyWith(
  codeTextStyle: monospaceTextStyle,
  verbatimTextStyle: monospaceTextStyle,
  blockTextStyle: monospaceTextStyle,
);

/// org_flutter's light and dark themes with [withMonospaceCode]. Getters,
/// because [monospaceFamily] depends on the platform.
abstract final class MonospaceOrgThemes {
  static OrgThemeData get light => withMonospaceCode(OrgThemeData.light());
  static OrgThemeData get dark => withMonospaceCode(OrgThemeData.dark());

  /// The same without padding around the document, as [OrgText] has.
  static OrgThemeData get lightTight => withMonospaceCode(
    OrgThemeData.light().copyWith(rootPadding: EdgeInsets.zero),
  );
  static OrgThemeData get darkTight => withMonospaceCode(
    OrgThemeData.dark().copyWith(rootPadding: EdgeInsets.zero),
  );
}
