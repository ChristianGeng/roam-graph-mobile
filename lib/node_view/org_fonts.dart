/// Org's ~code~ and =verbatim= in a monospace font (#238), as Emacs and
/// Org's export show them. org_flutter's own theme changes only their
/// colour, because its main user, Orgro, shows the whole document in a
/// monospace font.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:org_flutter/org_flutter.dart';

/// org_flutter's [OrgText] with [MonospaceOrgThemeData]: [OrgText] makes
/// its own themes and takes none. The rest is as [OrgText] builds it:
/// markup hidden, no padding, shrink-wrapped.
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
      lightTheme: MonospaceOrgThemeData.lightTight,
      darkTheme: MonospaceOrgThemeData.darkTight,
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

/// [OrgThemeData] that keeps every colour of [base] and adds the
/// monospace font to ~code~ and =verbatim=; the text around them keeps
/// its font. Source blocks, example blocks and fixed-width lines are not
/// reached through the theme in org_flutter 13.4.2 and stay as they are.
class MonospaceOrgThemeData extends OrgThemeData {
  MonospaceOrgThemeData(OrgThemeData base)
    : super(
        todoColor: base.todoColor,
        doneColor: base.doneColor,
        priorityColor: base.priorityColor,
        drawerColor: base.drawerColor,
        dateColor: base.dateColor,
        codeColor: base.codeColor,
        linkColor: base.linkColor,
        metaColor: base.metaColor,
        infoColor: base.infoColor,
        macroColor: base.macroColor,
        tableColor: base.tableColor,
        keywordColor: base.keywordColor,
        highlightColor: base.highlightColor,
        footnoteColor: base.footnoteColor,
        citationColor: base.citationColor,
        transcludeColor: base.transcludeColor,
        rootPadding: base.rootPadding,
        levelColors: base.levelColors,
        srcTheme: base.srcTheme,
      );

  /// org_flutter's light and dark themes with the monospace font.
  static final light = MonospaceOrgThemeData(OrgThemeData.light());
  static final dark = MonospaceOrgThemeData(OrgThemeData.dark());

  /// The same without padding around the document, as [OrgText] has.
  static final lightTight = MonospaceOrgThemeData(
    OrgThemeData.light().copyWith(rootPadding: EdgeInsets.zero),
  );
  static final darkTight = MonospaceOrgThemeData(
    OrgThemeData.dark().copyWith(rootPadding: EdgeInsets.zero),
  );

  @override
  TextStyle fontStyleForOrgStyle(TextStyle base, OrgStyle style) {
    final styled = super.fontStyleForOrgStyle(base, style);
    return switch (style) {
      OrgStyle.code || OrgStyle.verbatim => styled.copyWith(
        fontFamily: monospaceFamily,
        fontFamilyFallback: monospaceFallback,
      ),
      _ => styled,
    };
  }
}
