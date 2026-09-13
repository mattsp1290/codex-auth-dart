import 'package:flutter/material.dart';

import 'build_provenance.dart';
import 'evidence_controls.dart';

/// Separate debug-only entrypoint reserved for redacted evidence scenarios.
/// It is intentionally absent from the ordinary release import graph.
void main() => runApp(_EvidenceModeApp(EvidenceControls()));

final class _EvidenceModeApp extends StatelessWidget {
  const _EvidenceModeApp(this.controls);
  final EvidenceControls controls;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text(
          'Evidence ${BuildProvenance.packageCommit} (${BuildProvenance.flavor}): '
          '${controls.pauseAt?.name ?? 'idle'}',
        ),
      ),
    ),
  );
}
