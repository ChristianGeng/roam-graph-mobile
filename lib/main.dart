import 'package:flutter/material.dart';

/// The version the release workflow builds, passed in with
/// `--dart-define=APP_VERSION=...`. Local builds show "dev".
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

void main() {
  runApp(const RoamGraphApp());
}

class RoamGraphApp extends StatelessWidget {
  const RoamGraphApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Roam Graph',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

/// Placeholder until the spec is approved: shows the app name and version,
/// so an install through Obtainium can be checked.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Roam Graph')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Roam Graph', style: textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text('Version $appVersion', style: textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}
