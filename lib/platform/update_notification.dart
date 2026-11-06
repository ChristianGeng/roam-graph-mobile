/// Widgets and services for showing update notifications (#247).
library;

import 'package:flutter/material.dart';

import 'update_check.dart';

/// Global storage for the latest update check result.
///
/// This allows screens like AboutScreen to access the latest release
/// information without having to pass it through the widget tree.
class UpdateCheckResultStorage {
  static UpdateCheckResult? _latestResult;

  /// The latest update check result, or null if no check has been performed.
  static UpdateCheckResult? get latestResult => _latestResult;

  /// Sets the latest update check result.
  static set latestResult(UpdateCheckResult? result) => _latestResult = result;
}

/// Shows a snackbar notification when an update is available.
///
/// Returns true if the user tapped the action button.
Future<bool> showUpdateAvailableNotification(
  BuildContext context,
  GitHubRelease release,
  VoidCallback onUpdatePressed,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final controller = messenger.showSnackBar(
    SnackBar(
      content: Text('Update available: ${release.name}'),
      action: SnackBarAction(
        label: 'Update',
        onPressed: onUpdatePressed,
      ),
    ),
  );
  final result = await controller.closed;
  return result == SnackBarClosedReason.action;
}

/// A widget that checks for updates on start and shows a notification.
///
/// This should be placed near the root of the app widget tree.
class UpdateCheckerWidget extends StatefulWidget {
  const UpdateCheckerWidget({
    super.key,
    required this.version,
    required this.child,
    this.onUpdateAvailable,
    this.onUpdatePressed,
    this.checkOnStart = true,
    this.includePreReleases = false,
    this.loaded,
  });

  final String version;
  final Widget child;
  final ValueChanged<GitHubRelease>? onUpdateAvailable;
  final VoidCallback? onUpdatePressed;
  final bool checkOnStart;
  final bool includePreReleases;
  final Future<void>? loaded;

  @override
  State<UpdateCheckerWidget> createState() => _UpdateCheckerWidgetState();
}

class _UpdateCheckerWidgetState extends State<UpdateCheckerWidget> {
  late final UpdateChecker _updateChecker;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _updateChecker = UpdateChecker.simple(
      currentVersion: widget.version,
      includePreReleases: widget.includePreReleases,
    );
    if (widget.checkOnStart) {
      // Wait for settings to load before checking
      final loaded = widget.loaded ?? Future.value();
      loaded.then((_) => _checkForUpdates());
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checked) return;
    _checked = true;

    try {
      final result = await _updateChecker.checkForUpdates();
      // Store the result for other screens to access
      UpdateCheckResultStorage.latestResult = result;

      if (result.available && result.release != null && mounted) {
        // Notify via callback if provided
        if (widget.onUpdateAvailable != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              widget.onUpdateAvailable!(result.release!);
            }
          });
        }
      }
    } catch (_) {
      // Silently ignore errors
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A button that checks for updates when pressed.
class CheckForUpdatesButton extends StatelessWidget {
  const CheckForUpdatesButton({
    super.key,
    required this.version,
    required this.onUpdateAvailable,
    this.onNoUpdate = const _NoUpdateDialog(),
    this.onError,
  });

  final String version;
  final ValueChanged<GitHubRelease> onUpdateAvailable;
  final Widget onNoUpdate;
  final ValueChanged<String>? onError;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('check-for-updates'),
      icon: const Icon(Icons.system_update_outlined),
      tooltip: 'Check for updates',
      onPressed: () async {
        final checker = UpdateChecker(currentVersion: version);
        try {
          final result = await checker.checkForUpdates(force: true);
          // Store the result
          UpdateCheckResultStorage.latestResult = result;

          if (result.available && result.release != null) {
            onUpdateAvailable(result.release!);
          } else if (result.error != null) {
            onError?.call(result.error!);
          } else {
            // Show no update dialog
            // ignore: use_build_context_synchronously
            await showDialog(
              // ignore: use_build_context_synchronously
              context: context,
              builder: (context) => onNoUpdate,
            );
          }
        } catch (e) {
          onError?.call(e.toString());
        }
      },
    );
  }
}

/// Dialog shown when no update is available.
class _NoUpdateDialog extends StatelessWidget {
  const _NoUpdateDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('no-update-dialog'),
      title: const Text('No updates available'),
      content: const Text('You have the latest version.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// Dialog shown when an update is available with details.
class UpdateAvailableDialog extends StatelessWidget {
  const UpdateAvailableDialog({
    super.key,
    required this.release,
    required this.onUpdatePressed,
    this.showLinuxUpdateButton = true,
  });

  final GitHubRelease release;
  final VoidCallback onUpdatePressed;
  final bool showLinuxUpdateButton;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('update-available-dialog'),
      title: Text('Update available: ${release.name}'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Version: ${release.version}'),
            const SizedBox(height: 8),
            const Text('What\'s new:'),
            const SizedBox(height: 8),
            Text(release.body),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Later'),
        ),
        if (showLinuxUpdateButton)
          FilledButton(
            key: const ValueKey('update-now-button'),
            onPressed: () {
              Navigator.pop(context);
              onUpdatePressed();
            },
            child: const Text('Update now'),
          ),
      ],
    );
  }
}
