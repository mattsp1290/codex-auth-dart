import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'evidence_controller.dart';
import 'evidence_controls.dart';
import 'evidence_scenario_support.dart';
import 'evidence_state_store.dart';
import 'secure_credential_store.dart';

final class _ReauthenticationOutcome {
  const _ReauthenticationOutcome({
    required this.loginCommitted,
    required this.freshClient,
  });

  final bool loginCommitted;
  final bool freshClient;
}

/// Evidence-only orchestration for recovery rows that are absent from the
/// ordinary application graph.
final class EvidenceRecoveryScenarioApp extends StatefulWidget {
  const EvidenceRecoveryScenarioApp({
    super.key,
    required this.command,
    required this.stateStore,
  });

  final EvidenceCommand command;
  final EvidenceStateStore stateStore;

  @override
  State<EvidenceRecoveryScenarioApp> createState() =>
      _EvidenceRecoveryScenarioAppState();
}

final class _EvidenceRecoveryScenarioAppState
    extends State<EvidenceRecoveryScenarioApp> {
  EvidenceController? _loginController;
  String _finiteState = 'running';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      switch (widget.command.scenario) {
        case EvidenceScenario.twoClientRotation:
          await _runTwoClientRotation();
        case EvidenceScenario.invalidGrant:
          await _runInvalidGrant();
        case EvidenceScenario.expiredWithoutRefresh:
          await _runSeedRecovery(expired: true);
        case EvidenceScenario.malformedStore:
          await _runSeedRecovery(expired: false);
        default:
          throw StateError('unsupported recovery scenario');
      }
    } on Object {
      await _writeFailure();
    }
  }

  Future<void> _runTwoClientRotation() async {
    final state = SecureCredentialStore();
    final oldGeneration = await EvidenceCredentialMutation.generation(state);
    final staleAcknowledged = await EvidenceCredentialMutation.forceStale(
      state,
    );
    final tracker = EvidenceTransactionTracker();
    final transport = EvidenceTransport(DartIoHttpTransport());
    CodexAuthClient client() => CodexAuthClient(
      CodexAuthOptions(
        store: TrackedCredentialStore(SecureCredentialStore(), tracker),
        transport: transport,
      ),
    );

    var bothComplete = false;
    if (staleAcknowledged) {
      await Future.wait(<Future<Object?>>[
        client().listModels(const CatalogQuery('0.154.0')),
        client().listModels(const CatalogQuery('0.154.0')),
      ]);
      bothComplete = true;
    }
    final newGeneration = await EvidenceCredentialMutation.generation(
      SecureCredentialStore(),
    );
    var freshClient = false;
    if (bothComplete) {
      await client().listModels(const CatalogQuery('0.154.0'));
      freshClient = true;
    }
    final rotationObserved =
        oldGeneration != null &&
        newGeneration != null &&
        oldGeneration != newGeneration;
    final passed =
        staleAcknowledged &&
        transport.refreshCount == 1 &&
        rotationObserved &&
        bothComplete &&
        !tracker.overlapObserved &&
        freshClient;
    await _write(
      passed: passed,
      recovery: EvidenceRecovery.signedIn,
      protectedIo: transport.protectedIo,
      predicates: <String, Object?>{
        'refreshCount': transport.refreshCount,
        'rotationObserved': rotationObserved,
        'bothComplete': bothComplete,
        'noOverlapViolation': !tracker.overlapObserved,
        'freshClient': freshClient,
      },
    );
  }

  Future<void> _runInvalidGrant() async {
    final state = SecureCredentialStore();
    final staleAcknowledged = await EvidenceCredentialMutation.forceStale(
      state,
    );
    final transport = EvidenceTransport(
      DartIoHttpTransport(),
      substituteInvalidGrant: true,
    );
    var cleanupAcknowledged = false;
    if (staleAcknowledged) {
      try {
        await CodexAuthClient(
          CodexAuthOptions(store: state, transport: transport),
        ).listModels(const CatalogQuery('0.154.0'));
      } on CodexAuthException catch (error) {
        cleanupAcknowledged = error.requiresReauthentication;
      }
    }
    final recovered = await CodexAuthClient(
      CodexAuthOptions(
        store: SecureCredentialStore(),
        transport: DartIoHttpTransport(),
      ),
    ).status();
    cleanupAcknowledged =
        cleanupAcknowledged && recovered != AuthStatus.signedIn;
    final reauthentication = cleanupAcknowledged
        ? await _reauthenticateAndProbe()
        : const _ReauthenticationOutcome(
            loginCommitted: false,
            freshClient: false,
          );
    final freshClient = reauthentication.freshClient;
    final passed =
        staleAcknowledged &&
        transport.refreshCount == 1 &&
        transport.substitutionApplied &&
        transport.protectedIo == 0 &&
        cleanupAcknowledged &&
        freshClient;
    await _write(
      passed: passed,
      recovery: freshClient
          ? EvidenceRecovery.signedIn
          : EvidenceRecovery.reauthenticationRequired,
      protectedIo: transport.protectedIo,
      predicates: <String, Object?>{
        'refreshCount': transport.refreshCount,
        'cleanupAcknowledged': cleanupAcknowledged,
        'zeroProtectedIoBeforeReauthentication': transport.protectedIo == 0,
        'reauthenticated': reauthentication.loginCommitted,
        'freshClient': freshClient,
      },
    );
  }

  Future<void> _runSeedRecovery({required bool expired}) async {
    var seedAcknowledged = false;
    var cleanupAcknowledged = false;
    var reauthenticationCompleted = false;
    var freshClient = false;
    try {
      final state = SecureCredentialStore();
      if (expired) {
        await EvidenceCredentialMutation.seedExpiredWithoutRefresh(state);
      } else {
        await EvidenceCredentialMutation.seedMalformed(state);
      }
      seedAcknowledged = true;
      final transport = EvidenceTransport(DartIoHttpTransport());
      final recovered = await CodexAuthClient(
        CodexAuthOptions(store: state, transport: transport),
      ).status();
      cleanupAcknowledged = recovered == AuthStatus.reauthenticationRequired;
      final reauthentication = cleanupAcknowledged
          ? await _reauthenticateAndProbe()
          : const _ReauthenticationOutcome(
              loginCommitted: false,
              freshClient: false,
            );
      reauthenticationCompleted = reauthentication.loginCommitted;
      freshClient = reauthentication.freshClient;
      final passed =
          transport.refreshCount == 0 &&
          transport.protectedIo == 0 &&
          cleanupAcknowledged &&
          freshClient;
      await _write(
        passed: passed,
        recovery: freshClient
            ? EvidenceRecovery.signedIn
            : EvidenceRecovery.reauthenticationRequired,
        protectedIo: transport.protectedIo,
        predicates: <String, Object?>{
          'seedAcknowledged': seedAcknowledged,
          'zeroProtectedIo':
              transport.refreshCount == 0 && transport.protectedIo == 0,
          'cleanupAcknowledged': cleanupAcknowledged,
          'reauthenticated': reauthenticationCompleted,
          'freshClient': freshClient,
        },
      );
    } on Object {
      await _writeFailure(
        recovery: reauthenticationCompleted
            ? EvidenceRecovery.signedIn
            : cleanupAcknowledged
            ? EvidenceRecovery.reauthenticationRequired
            : EvidenceRecovery.cleanupRequired,
        predicates: <String, Object?>{
          'seedAcknowledged': seedAcknowledged,
          'cleanupAcknowledged': cleanupAcknowledged,
          'zeroProtectedIo': true,
          'reauthenticated': reauthenticationCompleted,
          'freshClient': freshClient,
        },
      );
    }
  }

  Future<_ReauthenticationOutcome> _reauthenticateAndProbe() async {
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
    final status = await controller.status();
    final loginCommitted =
        event.state == EvidenceState.passed && status == AuthStatus.signedIn;
    if (!loginCommitted) {
      return const _ReauthenticationOutcome(
        loginCommitted: false,
        freshClient: false,
      );
    }
    final result = await EvidenceController(
      CodexAuthClient(
        CodexAuthOptions(
          store: SecureCredentialStore(),
          transport: DartIoHttpTransport(),
        ),
      ),
    ).verifyCatalogAndUnavailable();
    return _ReauthenticationOutcome(
      loginCommitted: true,
      freshClient: result.allRequiredAdmitted,
    );
  }

  Future<void> _write({
    required bool passed,
    required EvidenceRecovery recovery,
    required int protectedIo,
    required Map<String, Object?> predicates,
  }) async {
    await widget.stateStore.writeResult(
      EvidenceResult(
        command: widget.command,
        state: passed ? EvidenceResultState.pass : EvidenceResultState.fail,
        recovery: recovery,
        protectedIo: protectedIo,
        predicates: predicates,
      ),
    );
    if (mounted) setState(() => _finiteState = passed ? 'passed' : 'failed');
  }

  Future<void> _writeFailure({
    EvidenceRecovery recovery = EvidenceRecovery.cleanupRequired,
    Map<String, Object?> predicates = const <String, Object?>{},
  }) => widget.stateStore.writeResult(
    EvidenceResult(
      command: widget.command,
      state: EvidenceResultState.fail,
      recovery: recovery,
      protectedIo: 0,
      category: 'requestFailed',
      predicates: predicates,
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
              Text('Recovery evidence: $_finiteState'),
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
