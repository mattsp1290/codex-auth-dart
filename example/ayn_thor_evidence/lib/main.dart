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
  const EvidenceHostApp({
    super.key,
    this.autoStartDeviceLogin = false,
    this.onDeviceLoginFinished,
    this.autoRunRequiredModels = false,
    this.onRequiredModelsFinished,
    this.autoRunCatalogEvidence = false,
    this.onCatalogEvidenceFinished,
  });

  final bool autoStartDeviceLogin;
  final Future<void> Function(EvidenceEvent event, AuthStatus status)?
  onDeviceLoginFinished;
  final bool autoRunRequiredModels;
  final Future<void> Function(
    AuthStatus status,
    Map<String, TupleEvidenceState> tuples,
  )?
  onRequiredModelsFinished;
  final bool autoRunCatalogEvidence;
  final Future<void> Function(AuthStatus status, CatalogEvidenceResult result)?
  onCatalogEvidenceFinished;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Codex authentication evidence',
    home: _EvidenceHome(
      autoStartDeviceLogin: autoStartDeviceLogin,
      onDeviceLoginFinished: onDeviceLoginFinished,
      autoRunRequiredModels: autoRunRequiredModels,
      onRequiredModelsFinished: onRequiredModelsFinished,
      autoRunCatalogEvidence: autoRunCatalogEvidence,
      onCatalogEvidenceFinished: onCatalogEvidenceFinished,
    ),
  );
}

final class _EvidenceHome extends StatefulWidget {
  const _EvidenceHome({
    required this.autoStartDeviceLogin,
    required this.onDeviceLoginFinished,
    required this.autoRunRequiredModels,
    required this.onRequiredModelsFinished,
    required this.autoRunCatalogEvidence,
    required this.onCatalogEvidenceFinished,
  });
  final bool autoStartDeviceLogin;
  final Future<void> Function(EvidenceEvent event, AuthStatus status)?
  onDeviceLoginFinished;
  final bool autoRunRequiredModels;
  final Future<void> Function(
    AuthStatus status,
    Map<String, TupleEvidenceState> tuples,
  )?
  onRequiredModelsFinished;
  final bool autoRunCatalogEvidence;
  final Future<void> Function(AuthStatus status, CatalogEvidenceResult result)?
  onCatalogEvidenceFinished;

  @override
  State<_EvidenceHome> createState() => _EvidenceHomeState();
}

final class _EvidenceHomeState extends State<_EvidenceHome>
    with WidgetsBindingObserver {
  late EvidenceController _controller;
  AuthStatus _durableStatus = AuthStatus.signedOut;
  var _automaticLoginStarted = false;
  var _automaticModelsStarted = false;
  var _automaticCatalogStarted = false;

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
    if (widget.autoStartDeviceLogin && !_automaticLoginStarted) {
      _automaticLoginStarted = true;
      unawaited(_runAutomaticDeviceLogin());
    }
  }

  Future<void> _runAutomaticDeviceLogin() async {
    final event = await _controller.startDeviceLogin();
    final status = await _controller.status();
    await widget.onDeviceLoginFinished?.call(event, status);
    if (mounted) setState(() => _durableStatus = status);
  }

  Future<void> _readDurableStatus() async {
    final status = await _controller.status();
    if (mounted) setState(() => _durableStatus = status);
    if (widget.autoRunRequiredModels && !_automaticModelsStarted) {
      _automaticModelsStarted = true;
      unawaited(_runAutomaticModels(status));
    }
    if (widget.autoRunCatalogEvidence && !_automaticCatalogStarted) {
      _automaticCatalogStarted = true;
      unawaited(_runAutomaticCatalog(status));
    }
  }

  Future<void> _runAutomaticModels(AuthStatus status) async {
    final tuples = status == AuthStatus.signedIn
        ? await _controller.runRequiredModels()
        : Map<String, TupleEvidenceState>.unmodifiable(_controller.tupleStates);
    await widget.onRequiredModelsFinished?.call(status, tuples);
  }

  Future<void> _runAutomaticCatalog(AuthStatus status) async {
    final result = status == AuthStatus.signedIn
        ? await _controller.verifyCatalogAndUnavailable()
        : const CatalogEvidenceResult(
            allRequiredAdmitted: false,
            unavailableRejected: false,
          );
    await widget.onCatalogEvidenceFinished?.call(status, result);
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
