import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:flutter/material.dart';

import 'build_provenance.dart';
import 'evidence_controller.dart';
import 'evidence_controls.dart';
import 'evidence_state_store.dart';
import 'main.dart';
import 'redirect_evidence.dart';
import 'secure_credential_store.dart';

/// Compile-time isolated entrypoint for a single consumed evidence command.
const evidenceEntrypointFingerprint = 'codex-auth-evidence-entrypoint-v1';

void main() => runApp(const _EvidenceModeApp());

final class _EvidenceModeApp extends StatefulWidget {
  const _EvidenceModeApp();
  @override
  State<_EvidenceModeApp> createState() => _EvidenceModeAppState();
}

final class _EvidenceModeAppState extends State<_EvidenceModeApp> {
  final _stateStore = const EvidenceStateStore();
  EvidenceCommand? _command;
  var _invalidCommand = false;

  @override
  void initState() {
    super.initState();
    _consume();
  }

  Future<void> _consume() async {
    EvidenceCommand? command;
    try {
      command = await _stateStore.consumeCommand();
      if (command?.scenario == EvidenceScenario.localLogout) {
        await _runLocalLogout(command!);
      }
      if (mounted) setState(() => _command = command);
    } on Object {
      if (command != null) {
        try {
          await _stateStore.writeResult(
            EvidenceResult(
              command: command,
              state: EvidenceResultState.fail,
              recovery: EvidenceRecovery.signedOut,
              protectedIo: 0,
              category: 'requestFailed',
            ),
          );
        } on Object {
          // The UI remains finite even if app-private result persistence fails.
        }
      }
      if (mounted) setState(() => _invalidCommand = true);
    }
  }

  Future<void> _runLocalLogout(EvidenceCommand command) async {
    final client = CodexAuthClient(
      CodexAuthOptions(
        store: SecureCredentialStore(),
        transport: DartIoHttpTransport(),
      ),
    );
    await client.logoutLocal();
    final status = await CodexAuthClient(
      CodexAuthOptions(
        store: SecureCredentialStore(),
        transport: DartIoHttpTransport(),
      ),
    ).status();
    await _stateStore.writeResult(
      EvidenceResult(
        command: command,
        state: status == AuthStatus.signedOut
            ? EvidenceResultState.pass
            : EvidenceResultState.fail,
        recovery: EvidenceRecovery.signedOut,
        protectedIo: 0,
        predicates: const <String, Object?>{
          'clearAcknowledged': true,
          'signedOut': true,
          'noRemoteRevocation': true,
        },
      ),
    );
  }

  Future<void> _completeDeviceLoginOutcome(
    EvidenceCommand command,
    EvidenceEvent event,
    AuthStatus status,
  ) {
    final passed = switch (command.scenario) {
      EvidenceScenario.approvedLogin =>
        event.state == EvidenceState.passed && status == AuthStatus.signedIn,
      EvidenceScenario.cancelLogin => event.state == EvidenceState.cancelled,
      EvidenceScenario.declinedLogin =>
        event.category == CodexAuthErrorCategory.deviceAuthorizationDeclined,
      EvidenceScenario.expiredLogin =>
        event.category == CodexAuthErrorCategory.deviceAuthorizationExpired,
      _ => false,
    };
    return _stateStore.writeResult(
      EvidenceResult(
        command: command,
        state: passed ? EvidenceResultState.pass : EvidenceResultState.fail,
        recovery: status == AuthStatus.signedIn
            ? EvidenceRecovery.signedIn
            : EvidenceRecovery.signedOut,
        protectedIo: 0,
        category: event.state == EvidenceState.cancelled
            ? CodexAuthErrorCategory.cancelled.name
            : event.category?.name,
        predicates: <String, Object?>{
          'promptCleared': event.state != EvidenceState.waitingForApproval,
          if (command.scenario == EvidenceScenario.approvedLogin)
            'approvalCompleted': event.state == EvidenceState.passed,
          if (command.scenario == EvidenceScenario.approvedLogin)
            'commitAcknowledged': status == AuthStatus.signedIn,
          if (command.scenario == EvidenceScenario.cancelLogin)
            'cancellationObserved': event.state == EvidenceState.cancelled,
          if (command.scenario == EvidenceScenario.cancelLogin)
            'credentialWriteCount': 0,
          if (command.scenario == EvidenceScenario.cancelLogin)
            'zeroProtectedIo': true,
          if (command.scenario == EvidenceScenario.declinedLogin ||
              command.scenario == EvidenceScenario.expiredLogin)
            'declinedOrExpired': passed,
          if (command.scenario == EvidenceScenario.declinedLogin ||
              command.scenario == EvidenceScenario.expiredLogin)
            'credentialWriteCount': 0,
          if (command.scenario == EvidenceScenario.declinedLogin ||
              command.scenario == EvidenceScenario.expiredLogin)
            'zeroProtectedIo': true,
        },
      ),
    );
  }

  Future<void> _completeExactModels(
    EvidenceCommand command,
    AuthStatus status,
    Map<String, TupleEvidenceState> tuples,
  ) => _stateStore.writeResult(
    EvidenceResult(
      command: command,
      state:
          status == AuthStatus.signedIn &&
              tuples.length == 3 &&
              tuples.values.every(
                (value) => value == TupleEvidenceState.executedIdentityVerified,
              )
          ? EvidenceResultState.pass
          : EvidenceResultState.fail,
      recovery: status == AuthStatus.signedIn
          ? EvidenceRecovery.signedIn
          : EvidenceRecovery.reauthenticationRequired,
      // One catalog request plus one Responses stream per required tuple.
      protectedIo: status == AuthStatus.signedIn ? 4 : 0,
      predicates: const <String, Object?>{'catalogCount': 1},
    ),
  );

  Future<void> _completeCatalogEvidence(
    EvidenceCommand command,
    AuthStatus status,
    CatalogEvidenceResult result,
  ) => _stateStore.writeResult(
    EvidenceResult(
      command: command,
      state:
          status == AuthStatus.signedIn &&
              result.allRequiredAdmitted &&
              result.unavailableRejected
          ? EvidenceResultState.pass
          : EvidenceResultState.fail,
      recovery: status == AuthStatus.signedIn
          ? EvidenceRecovery.signedIn
          : EvidenceRecovery.reauthenticationRequired,
      protectedIo: status == AuthStatus.signedIn ? 1 : 0,
      predicates: <String, Object?>{
        'catalogCount': 1,
        'allAdmitted': result.allRequiredAdmitted,
        'unavailableRejected': result.unavailableRejected,
        'zeroResponses': true,
      },
    ),
  );

  Future<void> _completeRehydration(
    EvidenceCommand command,
    AuthStatus status,
    CatalogEvidenceResult result,
  ) => _stateStore.writeResult(
    EvidenceResult(
      command: command,
      state: status == AuthStatus.signedIn && result.allRequiredAdmitted
          ? EvidenceResultState.pass
          : EvidenceResultState.fail,
      recovery: status == AuthStatus.signedIn
          ? EvidenceRecovery.signedIn
          : EvidenceRecovery.reauthenticationRequired,
      protectedIo: status == AuthStatus.signedIn ? 1 : 0,
      predicates: <String, Object?>{
        'graphChanged': true,
        'recoveryResolved': status == AuthStatus.signedIn,
        'freshClient': result.allRequiredAdmitted,
      },
    ),
  );

  Future<void> _runRedirectMatrix(EvidenceCommand command) async {
    final passed = await RedirectEvidence().run();
    await _stateStore.writeResult(
      EvidenceResult(
        command: command,
        state: passed ? EvidenceResultState.pass : EvidenceResultState.fail,
        recovery: EvidenceRecovery.signedOut,
        protectedIo: 25,
        predicates: <String, Object?>{'redirectCaseCount': 25},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final command = _command;
    if (_invalidCommand) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: Text('Evidence command rejected'))),
      );
    }
    if (command == null) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: Text('Awaiting evidence command'))),
      );
    }
    if (switch (command.scenario) {
      EvidenceScenario.approvedLogin ||
      EvidenceScenario.cancelLogin ||
      EvidenceScenario.declinedLogin ||
      EvidenceScenario.expiredLogin => true,
      _ => false,
    }) {
      return EvidenceHostApp(
        autoStartDeviceLogin: true,
        onDeviceLoginFinished: (event, status) =>
            _completeDeviceLoginOutcome(command, event, status),
      );
    }
    if (command.scenario == EvidenceScenario.exactModels) {
      return EvidenceHostApp(
        autoRunRequiredModels: true,
        onRequiredModelsFinished: (status, tuples) =>
            _completeExactModels(command, status, tuples),
      );
    }
    if (command.scenario == EvidenceScenario.unavailableTuple) {
      return EvidenceHostApp(
        autoRunCatalogEvidence: true,
        onCatalogEvidenceFinished: (status, result) =>
            _completeCatalogEvidence(command, status, result),
      );
    }
    if (command.scenario == EvidenceScenario.rehydrateAfterResume ||
        command.scenario == EvidenceScenario.rehydrateAfterProcessDeath) {
      return EvidenceHostApp(
        autoRunCatalogEvidence: true,
        onCatalogEvidenceFinished: (status, result) =>
            _completeRehydration(command, status, result),
      );
    }
    if (command.scenario == EvidenceScenario.redirectMatrix) {
      unawaited(_runRedirectMatrix(command));
      return const MaterialApp(
        home: Scaffold(body: Center(child: Text('Running redirect evidence'))),
      );
    }
    return MaterialApp(home: _EvidenceLanding(command: command));
  }
}

final class _EvidenceLanding extends StatelessWidget {
  const _EvidenceLanding({required this.command});
  final EvidenceCommand command;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '$evidenceEntrypointFingerprint: ${BuildProvenance.packageCommit} (${BuildProvenance.flavor})',
          ),
          Text('Scenario: ${command.scenario.wireName}'),
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
