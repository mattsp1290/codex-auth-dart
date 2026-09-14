import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:flutter/material.dart';

import 'evidence_controller.dart';
import 'evidence_controls.dart';
import 'evidence_scenario_support.dart';
import 'evidence_state_store.dart';
import 'secure_credential_store.dart';

/// Proves that recovery resolves from durable state before a reconstructed
/// client graph performs protected I/O.
final class EvidenceRehydrationScenarioApp extends StatefulWidget {
  const EvidenceRehydrationScenarioApp({
    super.key,
    required this.command,
    required this.stateStore,
    this.checkpoint,
  });

  final EvidenceCommand command;
  final EvidenceStateStore stateStore;
  final EvidenceCheckpoint? checkpoint;

  @override
  State<EvidenceRehydrationScenarioApp> createState() =>
      _EvidenceRehydrationScenarioAppState();
}

final class _EvidenceRehydrationScenarioAppState
    extends State<EvidenceRehydrationScenarioApp>
    with WidgetsBindingObserver {
  var _finiteState = 'running';
  Completer<void>? _resumed;
  var _leftForeground = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      if (widget.checkpoint == null) {
        if (widget.command.scenario == EvidenceScenario.rehydrateAfterResume) {
          _resumed = Completer<void>();
        }
        await widget.stateStore.writeCheckpoint(
          EvidenceCheckpoint(
            command: widget.command,
            phase: EvidenceCheckpointPhase.rehydrationReady,
            refreshResponseCount: 0,
            replacementAcknowledged: false,
            replacementGenerationVerified: false,
          ),
        );
        if (widget.command.scenario ==
            EvidenceScenario.rehydrateAfterProcessDeath) {
          await Completer<Never>().future;
        }
        await _resumed!.future;
        await widget.stateStore.clearCheckpoint();
      }
      final checkpoint = widget.checkpoint;
      if (checkpoint != null &&
          (checkpoint.command.nonce != widget.command.nonce ||
              checkpoint.phase != EvidenceCheckpointPhase.rehydrationReady)) {
        throw StateError('rehydration checkpoint mismatch');
      }

      final transport = EvidenceTransport(DartIoHttpTransport());
      final client = CodexAuthClient(
        CodexAuthOptions(store: SecureCredentialStore(), transport: transport),
      );
      final status = await client.status();
      final resolvedBeforeProtectedIo = transport.protectedIo == 0;
      var freshClient = false;
      if (status == AuthStatus.signedIn) {
        final catalog = await EvidenceController(client)
            .verifyCatalogAndUnavailable();
        freshClient = catalog.allRequiredAdmitted;
      }
      final passed =
          status == AuthStatus.signedIn &&
          resolvedBeforeProtectedIo &&
          freshClient;
      if (checkpoint != null) await widget.stateStore.clearCheckpoint();
      await widget.stateStore.writeResult(
        EvidenceResult(
          command: widget.command,
          state: passed ? EvidenceResultState.pass : EvidenceResultState.fail,
          recovery: status == AuthStatus.signedIn
              ? EvidenceRecovery.signedIn
              : EvidenceRecovery.reauthenticationRequired,
          protectedIo: transport.protectedIo,
          predicates: <String, Object?>{
            if (widget.command.scenario ==
                EvidenceScenario.rehydrateAfterResume)
              'graphChanged': true
            else
              'processChanged': false,
            'recoveryResolved': status == AuthStatus.signedIn,
            'noLoginRepeated': true,
            'resolvedBeforeProtectedIo': resolvedBeforeProtectedIo,
            'freshClient': freshClient,
          },
        ),
      );
      if (mounted) setState(() => _finiteState = passed ? 'passed' : 'failed');
    } on Object {
      await widget.stateStore.writeResult(
        EvidenceResult(
          command: widget.command,
          state: EvidenceResultState.fail,
          recovery: EvidenceRecovery.cleanupRequired,
          protectedIo: 0,
          category: 'requestFailed',
        ),
      );
      if (mounted) setState(() => _finiteState = 'failed');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _leftForeground = true;
    } else if (state == AppLifecycleState.resumed && _leftForeground) {
      final resumed = _resumed;
      if (resumed != null && !resumed.isCompleted) resumed.complete();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(child: Text('Rehydration evidence: $_finiteState')),
    ),
  );
}
