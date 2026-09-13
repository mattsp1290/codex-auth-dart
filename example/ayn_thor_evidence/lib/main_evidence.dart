import 'package:flutter/material.dart';

import 'build_provenance.dart';
import 'evidence_controls.dart';
import 'main.dart';

/// Separate debug-only entrypoint reserved for redacted evidence scenarios.
/// It is intentionally absent from the ordinary release import graph.
void main() => runApp(_EvidenceModeApp(EvidenceControls()));

final class _EvidenceModeApp extends StatelessWidget {
  const _EvidenceModeApp(this.controls);
  final EvidenceControls controls;

  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: _EvidenceLanding(controls));
}

final class _EvidenceLanding extends StatelessWidget {
  const _EvidenceLanding(this.controls);
  final EvidenceControls controls;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Evidence ${BuildProvenance.packageCommit} (${BuildProvenance.flavor}): '
            '${controls.pauseAt?.name ?? 'idle'}',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _EvidenceHostRoute(),
              ),
            ),
            child: const Text('Open authentication harness'),
          ),
        ],
      ),
    ),
  );
}

final class _EvidenceHostRoute extends StatelessWidget {
  const _EvidenceHostRoute();

  @override
  Widget build(BuildContext context) => const EvidenceHostApp();
}
