/// The page "About" (#207): the installed version, what is new, the
/// releases on GitHub and the licences.
library;

import 'package:material_ui/material_ui.dart';

import '../node_view/web_links.dart';
import '../platform/desktop.dart';
import '../platform/error_text.dart' show copyToClipboard;
import '../platform/update_check.dart' show GitHubRelease, UpdateChecker;
import '../platform/update_notification.dart' show UpdateCheckerScope;

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
    final title = heading;
    if (title != null) {
      entries.add(
          ChangelogEntry(_plain(title), _plain(body.join('\n').trim())));
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
    this.release,
    this.checker,
  });

  final String version;
  final UrlOpener openUrl;
  final GitHubRelease? release;

  /// The app's one update checker, from the [UpdateCheckerScope]; null in
  /// tests or when there is none.
  final UpdateChecker? checker;

  static Future<void> open(BuildContext context,
          {required String version,
          UrlOpener openUrl = openUrlOnDevice,
          GitHubRelease? release,
          UpdateChecker? checker}) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => AboutScreen(
                version: version,
                openUrl: openUrl,
                release: release,
                checker: checker ?? UpdateCheckerScope.maybeOf(context))),
      );

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  Future<String>? _changelog;
  int _shown = changelogPageSize;
  GitHubRelease? _effectiveRelease;
  String? _checkStatus;
  bool _checkingForUpdates = false;

  @override
  void initState() {
    super.initState();
    final checker = widget.checker;
    _effectiveRelease = widget.release ?? checker?.lastResult?.release;
    // Check on open only when checking is on (on Android only if the
    // user turned it on, #247).
    if (_effectiveRelease == null &&
        checker != null &&
        checker.settings.checkForUpdates) {
      _checkForUpdates();
    }
  }

  Future<void> _checkForUpdates() async {
    final checker = widget.checker;
    if (checker == null || _checkingForUpdates) return;
    _checkingForUpdates = true;
    try {
      final result = await checker.checkForUpdates(force: true);
      if (!mounted) return;
      setState(() {
        if (result.available && result.release != null) {
          _effectiveRelease = result.release;
          _checkStatus = 'Update available: ${result.release!.version}';
        } else if (result.error != null) {
          _checkStatus = 'Check failed: ${result.error}';
        } else {
          _checkStatus = 'Up to date';
        }
      });
    } finally {
      if (mounted) {
        setState(() => _checkingForUpdates = false);
      }
    }
  }

  /// Checks if the app was installed via install.sh on Linux.
  Future<bool> _isInstalledViaInstallSh() async =>
      isDesktop && await UpdateChecker.isInstalledViaInstallSh();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _changelog ??= DefaultAssetBundle.of(context).loadString(changelogAsset);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
        actions: [
          if (widget.checker != null)
            IconButton(
              key: const ValueKey('about-check-for-updates'),
              icon: const Icon(Icons.refresh),
              tooltip: 'Check for updates',
              onPressed: _checkForUpdates,
            ),
        ],
      ),
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
          if (_checkStatus != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _checkStatus!,
                key: const ValueKey('about-check-status'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          if (_effectiveRelease != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Update available: ${_effectiveRelease!.name}',
                    key: const ValueKey('about-update-available'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "What's new",
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(_effectiveRelease!.body),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('about-view-release'),
                          onPressed: () => openExternalLink(
                            context,
                            Uri.parse(_effectiveRelease!.htmlUrl),
                            widget.openUrl,
                          ),
                          child: const Text('View release on GitHub'),
                        ),
                      ),
                      if (isDesktop) ...[
                        const SizedBox(width: 8),
                        FutureBuilder<bool>(
                          future: _isInstalledViaInstallSh(),
                          builder: (context, snapshot) {
                            final installedViaInstallSh = snapshot.data ?? false;
                            if (!installedViaInstallSh) {
                              // On Windows/macOS, show download link
                              return FilledButton(
                                key: const ValueKey('about-download-update'),
                                onPressed: () => openExternalLink(
                                  context,
                                  Uri.parse(_effectiveRelease!.htmlUrl),
                                  widget.openUrl,
                                ),
                                child: const Text('Download update'),
                              );
                            }
                            // On Linux with install.sh, show update and restart
                            return FilledButton(
                              key: const ValueKey('about-update-and-restart'),
                              onPressed: () async {
                                final messenger =
                                    ScaffoldMessenger.of(context);
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Update and restart'),
                                    content: const Text(
                                      'This will run install.sh --update and restart the app. Continue?',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        child: const Text('Update and restart'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  try {
                                    // Runs install.sh --update, then
                                    // starts the new app and quits this
                                    // one; only on success.
                                    await UpdateChecker.updateAndRestart();
                                  } catch (e) {
                                    if (mounted) {
                                      messenger.showSnackBar(
                                        SnackBar(
                                            content:
                                                Text('Update failed: $e')),
                                      );
                                    }
                                  }
                                }
                              },
                              child: const Text('Update and restart'),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
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
