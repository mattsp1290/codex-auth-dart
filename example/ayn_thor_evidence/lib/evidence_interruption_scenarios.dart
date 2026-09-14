import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'evidence_controller.dart';
import 'evidence_controls.dart';
import 'evidence_scenario_support.dart';
import 'evidence_state_store.dart';
import 'secure_credential_store.dart';

/// Runs one refresh interruption until a durable checkpoint, then resumes from
/// a fresh process using only the checkpoint's closed metadata.
final class EvidenceInterruptionScenarioApp extends StatefulWidget {
  const EvidenceInterruptionScenarioApp({
    super.key,
    required this.command,
    required this.stateStore,
    this.checkpoint,
  });

  final EvidenceCommand command;
  final EvidenceStateStore stateStore;
  final EvidenceCheckpoint? checkpoint;

  @override
  State<EvidenceInterruptionScenarioApp> createState() =>
      _EvidenceInterruptionScenarioAppState();
}

final class _EvidenceInterruptionScenarioAppState
    extends State<EvidenceInterruptionScenarioApp> {
  EvidenceController? _loginController;
  String _finiteState = 'running';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final checkpoint = widget.checkpoint;
      if (checkpoint == null) {
        await _runUntilCheckpoint();
      } else {
        await _recover(checkpoint);
      }
    } on Object {
      await _writeFailure();
    }
  }

  Future<void> _runUntilCheckpoint() async {
    final phase = _phase(widget.command.scenario);
    final stale = await EvidenceCredentialMutation.forceStale(
      SecureCredentialStore(),
    );
    if (!stale) throw StateError('interruption precondition unavailable');
    final client = CodexAuthClient(
      CodexAuthOptions(
        store: PausingCredentialStore(
          SecureCredentialStore(),
          stateStore: widget.stateStore,
          command: widget.command,
          phase: phase,
        ),
        transport: DartIoHttpTransport(),
      ),
    );
    await client.listModels(const CatalogQuery('0.154.0'));
    throw StateError('interruption checkpoint was not held');
  }

  Future<void> _recover(EvidenceCheckpoint checkpoint) async {
    if (checkpoint.command.nonce != widget.command.nonce ||
        checkpoint.phase != _phase(widget.command.scenario)) {
      throw StateError('interruption checkpoint mismatch');
    }
    final transport = EvidenceTransport(DartIoHttpTransport());
    final status = await CodexAuthClient(
      CodexAuthOptions(store: SecureCredentialStore(), transport: transport),
    ).status();
    final resolvedBeforeProtectedIo = transport.protectedIo == 0;
    var reauthenticated = false;
    var freshClient = false;
    if (checkpoint.phase == EvidenceCheckpointPhase.afterReplacement) {
      if (status == AuthStatus.signedIn) {
        freshClient = await _probeFreshClient(transport);
      }
    } else if (status == AuthStatus.reauthenticationRequired) {
      reauthenticated = await _reauthenticate();
      if (reauthenticated) {
        freshClient = await _probeFreshClient(transport);
      }
    }

    final predicates = switch (checkpoint.phase) {
      EvidenceCheckpointPhase.rehydrationReady => throw StateError(
        'invalid refresh checkpoint phase',
      ),
      EvidenceCheckpointPhase.refreshRisk => <String, Object?>{
        'refreshRiskAcknowledged': true,
        'processChanged': false,
        'oldStateCleared': status == AuthStatus.reauthenticationRequired,
        'zeroProtectedIoBeforeResolution': resolvedBeforeProtectedIo,
        'reauthenticated': reauthenticated,
        'freshClient': freshClient,
      },
      EvidenceCheckpointPhase.beforeReplacement => <String, Object?>{
        'refreshResponseCount': checkpoint.refreshResponseCount,
        'refreshRiskAcknowledged': true,
        'replacementNotAcknowledged': !checkpoint.replacementAcknowledged,
        'processChanged': false,
        'oldStateCleared': status == AuthStatus.reauthenticationRequired,
        'zeroProtectedIoBeforeResolution': resolvedBeforeProtectedIo,
        'reauthenticated': reauthenticated,
        'freshClient': freshClient,
      },
      EvidenceCheckpointPhase.afterReplacement => <String, Object?>{
        'refreshResponseCount': checkpoint.refreshResponseCount,
        'replacementAcknowledged': checkpoint.replacementAcknowledged,
        'operationSuccessNotReported': true,
        'processChanged': false,
        'replacementGenerationVerified':
            checkpoint.replacementGenerationVerified,
        'resolvedBeforeProtectedIo': resolvedBeforeProtectedIo,
        'freshClient': freshClient,
      },
    };
    final passed = predicates.entries
        .where((entry) => !entry.key.endsWith('Count'))
        .every((entry) => entry.key == 'processChanged' || entry.value == true);
    await widget.stateStore.clearCheckpoint();
    await widget.stateStore.writeResult(
      EvidenceResult(
        command: widget.command,
        state: passed ? EvidenceResultState.pass : EvidenceResultState.fail,
        recovery: status == AuthStatus.signedIn
            ? EvidenceRecovery.signedIn
            : reauthenticated
            ? EvidenceRecovery.signedIn
            : EvidenceRecovery.reauthenticationRequired,
        protectedIo: transport.protectedIo,
        predicates: predicates,
      ),
    );
    if (mounted) setState(() => _finiteState = passed ? 'passed' : 'failed');
  }

  Future<bool> _reauthenticate() async {
    final controller = EvidenceController(
      CodexAuthClient(
        CodexAuthOptions(
          store: SecureCredentialStore(),
          transport: DartIoHttpTransport(),
        ),
      ),
    )..addListener(_changed);
    _loginController = controller;
    if (mounted) setState(() => _finiteState = 'reauthentication-required');
    final event = await controller.startDeviceLogin();
    return event.state == EvidenceState.passed &&
        await controller.status() == AuthStatus.signedIn;
  }

  Future<bool> _probeFreshClient(EvidenceTransport transport) async {
    final result = await EvidenceController(
      CodexAuthClient(
        CodexAuthOptions(store: SecureCredentialStore(), transport: transport),
      ),
    ).verifyCatalogAndUnavailable();
    return result.allRequiredAdmitted;
  }

  EvidenceCheckpointPhase _phase(EvidenceScenario scenario) =>
      switch (scenario) {
        EvidenceScenario.interruptAfterRefreshRisk =>
          EvidenceCheckpointPhase.refreshRisk,
        EvidenceScenario.interruptBeforeReplacementCommit =>
          EvidenceCheckpointPhase.beforeReplacement,
        EvidenceScenario.interruptAfterReplacementCommit =>
          EvidenceCheckpointPhase.afterReplacement,
        _ => throw StateError('unsupported interruption scenario'),
      };

  Future<void> _writeFailure() => widget.stateStore.writeResult(
    EvidenceResult(
      command: widget.command,
      state: EvidenceResultState.fail,
      recovery: EvidenceRecovery.cleanupRequired,
      protectedIo: 0,
      category: 'requestFailed',
    ),
  );

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _loginController?.removeListener(_changed);
    _loginController?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prompt = _loginController?.prompt;
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('Interruption evidence: $_finiteState'),
              if (prompt != null) ...<Widget>[
                const Text('Approve this code in your browser:'),
                Text(prompt.userCode),
                FilledButton(
                  onPressed: () => launchUrl(
                    prompt.verificationUri,
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Open browser'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
