import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'build_provenance.dart';
import 'evidence_controller.dart';
import 'secure_credential_store.dart';

void main() => runApp(const EvidenceHostApp());

/// Ordinary host entrypoint. It deliberately imports no evidence controls.
final class EvidenceHostApp extends StatelessWidget {
  const EvidenceHostApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'Codex authentication evidence',
    home: _EvidenceHome(),
  );
}

final class _EvidenceHome extends StatefulWidget {
  const _EvidenceHome();

  @override
  State<_EvidenceHome> createState() => _EvidenceHomeState();
}

final class _EvidenceHomeState extends State<_EvidenceHome>
    with WidgetsBindingObserver {
  late EvidenceController _controller;
  AuthStatus _durableStatus = AuthStatus.signedOut;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rebuildGraph();
  }

  void _rebuildGraph() {
    _controller = EvidenceController(
      CodexAuthClient(
        CodexAuthOptions(
          store: SecureCredentialStore(),
          transport: DartIoHttpTransport(),
        ),
      ),
    )..addListener(_changed);
    unawaited(_readDurableStatus());
  }

  Future<void> _readDurableStatus() async {
    final status = await _controller.status();
    if (mounted) setState(() => _durableStatus = status);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _controller.removeListener(_changed);
    _controller.cancel();
    _rebuildGraph();
    if (mounted) setState(() {});
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_changed);
    _controller.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prompt = _controller.prompt;
    return Scaffold(
      appBar: AppBar(title: const Text('Codex authentication evidence')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('State: ${_controller.state.name} ($_durableStatus)'),
            Text(
              'Build: ${BuildProvenance.packageCommit} (${BuildProvenance.flavor})',
            ),
            const SizedBox(height: 16),
            if (prompt != null) ...<Widget>[
              const Text('Approve this code in your browser:'),
              Text(prompt.userCode),
              Text(prompt.verificationUri.toString()),
              FilledButton(
                onPressed: () => launchUrl(
                  prompt.verificationUri,
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('Open browser'),
              ),
              TextButton(
                onPressed: _controller.cancel,
                child: const Text('Cancel'),
              ),
            ] else ...<Widget>[
              FilledButton(
                onPressed: _controller.state == EvidenceState.waitingForApproval
                    ? null
                    : () => unawaited(_controller.startDeviceLogin()),
                child: const Text('Start device login'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _controller.state == EvidenceState.passed
                    ? () => unawaited(_controller.runRequiredModels())
                    : null,
                child: const Text('Run exact-model evidence'),
              ),
              for (final entry in _controller.tupleStates.entries)
                Text('${entry.key}: ${entry.value.name}'),
            ],
          ],
        ),
      ),
    );
  }
}
