/// The one update checker of the app, shared by the start screen and the
/// About page, and the widget that checks for updates on start (#247).
library;

import 'package:flutter/material.dart';

import 'update_check.dart';

/// Gives the app's single [UpdateChecker] to the screens below it.
class UpdateCheckerScope extends InheritedWidget {
  const UpdateCheckerScope({
    super.key,
    required this.checker,
    required super.child,
  });

  final UpdateChecker checker;

  /// The checker of the app, or null outside a [UpdateCheckerScope].
  static UpdateChecker? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UpdateCheckerScope>()
          ?.checker;

  @override
  bool updateShouldNotify(UpdateCheckerScope oldWidget) =>
      checker != oldWidget.checker;
}

/// Checks for updates on start and shows a notice when one is available.
///
/// Place near the root of the app, inside an [UpdateCheckerScope]. Waits
/// for [loaded] (the settings) before checking, so a saved opt-out
/// applies; the checker itself re-reads the settings anyway.
class UpdateCheckerWidget extends StatefulWidget {
  const UpdateCheckerWidget({
    super.key,
    required this.checker,
    required this.child,
    this.onUpdateAvailable,
    this.loaded,
  });

  final UpdateChecker checker;
  final Widget child;
  final ValueChanged<GitHubRelease>? onUpdateAvailable;
  final Future<void>? loaded;

  @override
  State<UpdateCheckerWidget> createState() => _UpdateCheckerWidgetState();
}

class _UpdateCheckerWidgetState extends State<UpdateCheckerWidget> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    final loaded = widget.loaded ?? Future.value();
    loaded.then((_) {
      if (mounted) _checkForUpdates();
    });
  }

  Future<void> _checkForUpdates() async {
    if (_checked) return;
    _checked = true;
    final result = await widget.checker.checkForUpdates();
    if (result.available && result.release != null && mounted) {
      final release = result.release!;
      final onUpdateAvailable = widget.onUpdateAvailable;
      if (onUpdateAvailable != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) onUpdateAvailable(release);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
