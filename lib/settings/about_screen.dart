/// The page "About" (#207): the installed version, what is new, the
/// releases on GitHub and the licences.
library;

import 'package:material_ui/material_ui.dart';

import '../node_view/web_links.dart';
import '../platform/error_text.dart' show copyToClipboard;

/// The page with all releases, pre-releases included.
final releasesUri =
    Uri.parse('https://github.com/ChristianGeng/roam-graph-mobile/releases');

/// How many changelog entries show before "Show more".
const changelogPageSize = 20;

/// The asset with the changelog.
const changelogAsset = 'CHANGELOG.md';

/// The version as the Settings row and the About page show it: "Version
/// 0.2.0-dev.473 (pre-release)"; a local build ("dev") shows "Version dev".
String versionLabel(String version) => version.contains('-dev.')
    ? 'Version $version (pre-release)'
    : 'Version $version';

/// One entry of CHANGELOG.md: its heading without the `## `, and the lines
/// below it.
class ChangelogEntry {
  const ChangelogEntry(this.heading, this.body);

  final String heading;
  final String body;
}

/// The entries of [changelog], newest first as in the file. An entry is a
/// `## ` heading and the lines up to the next one; the text before the
/// first heading is not an entry. Links `[text](address)` show as `text`.
List<ChangelogEntry> parseChangelog(String changelog) {
  final entries = <ChangelogEntry>[];
  String? heading;
  final body = <String>[];
  void finish() {
    if (heading != null) {
      entries.add(ChangelogEntry(_plain(heading!), _plain(body.join('\n').trim())));
    }
    body.clear();
  }

  for (final line in changelog.split('\n')) {
    if (line.startsWith('## ')) {
      finish();
      heading = line.substring(3).trim();
    } else {
      body.add(line);
    }
  }
  finish();
  return entries;
}

String _plain(String text) => text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'), (match) => match[1]!);

/// The About page.
class AboutScreen extends StatefulWidget {
  const AboutScreen({
    super.key,
    required this.version,
    this.openUrl = openUrlOnDevice,
  });

  final String version;
  final UrlOpener openUrl;

  static Future<void> open(BuildContext context,
          {required String version, UrlOpener openUrl = openUrlOnDevice}) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => AboutScreen(version: version, openUrl: openUrl)),
      );

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  Future<String>? _changelog;
  int _shown = changelogPageSize;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _changelog ??= DefaultAssetBundle.of(context).loadString(changelogAsset);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    versionLabel(widget.version),
                    key: const ValueKey('about-version'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const ValueKey('about-copy-version'),
                  tooltip: 'Copy version',
                  onPressed: () => copyToClipboard(ScaffoldMessenger.of(context),
                      versionLabel(widget.version)),
                  icon: const Icon(Icons.copy, size: 20),
                ),
              ],
            ),
          ),
          ListTile(
            key: const ValueKey('about-releases'),
            leading: const Icon(Icons.open_in_new),
            title: const Text('All releases on GitHub'),
            subtitle: const Text('Pre-releases are listed there too'),
            onTap: () =>
                openExternalLink(context, releasesUri, widget.openUrl),
          ),
          ListTile(
            key: const ValueKey('about-licences'),
            leading: const Icon(Icons.description_outlined),
            title: const Text('Licences'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Roam Graph',
              applicationVersion: widget.version,
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text("What's new", style: theme.textTheme.titleSmall),
          ),
          FutureBuilder<String>(
            future: _changelog,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const ListTile(
                  key: ValueKey('about-changelog-error'),
                  title: Text('The changelog could not be read.'),
                );
              }
              final text = snapshot.data;
              if (text == null) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final entries = parseChangelog(text);
              final shown = entries.take(_shown).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in shown)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.heading,
                              style: theme.textTheme.titleSmall),
                          if (entry.body.isNotEmpty) Text(entry.body),
                        ],
                      ),
                    ),
                  if (entries.length > shown.length)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const ValueKey('about-show-more'),
                          onPressed: () =>
                              setState(() => _shown += changelogPageSize),
                          child: const Text('Show more'),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
