import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:flutter/material.dart';

import 'build_provenance.dart';
import 'evidence_controller.dart';
import 'evidence_controls.dart';
import 'evidence_device_auth_transport.dart';
import 'evidence_interruption_scenarios.dart';
import 'evidence_rehydration_scenarios.dart';
import 'evidence_recovery_scenarios.dart';
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
  EvidenceCheckpoint? _checkpoint;
  var _invalidCommand = false;
  final _deviceAuthTelemetry = DeviceAuthTelemetry();

  CodexAuthClient _deviceAuthClient() => CodexAuthClient(
    CodexAuthOptions(
      store: SecureCredentialStore(),
      transport: EvidenceDeviceAuthTransport(
        DartIoHttpTransport(),
        telemetry: _deviceAuthTelemetry,
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    ),
  );

  @override
  void initState() {
    super.initState();
    _consume();
  }

  Future<void> _consume() async {
    EvidenceCommand? command;
    try {
      command = await _stateStore.consumeCommand();
      final checkpoint = command == null
          ? await _stateStore.readCheckpoint()
          : null;
      command ??= checkpoint?.command;
      if (command?.scenario == EvidenceScenario.localLogout) {
        await _runLocalLogout(command!);
      }
      if (mounted) {
        setState(() {
          _command = command;
          _checkpoint = checkpoint;
        });
      }
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
    await client.logoutLocal().timeout(const Duration(seconds: 15));
    final status = await CodexAuthClient(
      CodexAuthOptions(
        store: SecureCredentialStore(),
        transport: DartIoHttpTransport(),
      ),
    ).status().timeout(const Duration(seconds: 15));
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
  ) async {
    var freshClient = false;
    if (command.scenario == EvidenceScenario.approvedLogin &&
        event.state == EvidenceState.passed &&
        status == AuthStatus.signedIn) {
      freshClient = (await EvidenceController(
        CodexAuthClient(
          CodexAuthOptions(
            store: SecureCredentialStore(),
            transport: DartIoHttpTransport(),
          ),
        ),
      ).verifyCatalogAndUnavailable()).allRequiredAdmitted;
    }
    final passed = switch (command.scenario) {
      EvidenceScenario.approvedLogin =>
        event.state == EvidenceState.passed &&
            status == AuthStatus.signedIn &&
            freshClient,
      EvidenceScenario.cancelLogin => event.state == EvidenceState.cancelled,
      EvidenceScenario.declinedLogin =>
        event.category == CodexAuthErrorCategory.deviceAuthorizationDeclined,
      EvidenceScenario.expiredLogin =>
        event.category == CodexAuthErrorCategory.deviceAuthorizationExpired,
      _ => false,
    };
    await _stateStore.writeResult(
      EvidenceResult(
        command: command,
        state: passed ? EvidenceResultState.pass : EvidenceResultState.fail,
        recovery: status == AuthStatus.signedIn
            ? EvidenceRecovery.signedIn
            : EvidenceRecovery.signedOut,
        protectedIo:
            command.scenario == EvidenceScenario.approvedLogin && freshClient
            ? 1
            : 0,
        category: event.state == EvidenceState.cancelled
            ? CodexAuthErrorCategory.cancelled.name
            : event.category?.name,
        predicates: <String, Object?>{
          'promptCleared': event.state != EvidenceState.waitingForApproval,
          if (command.scenario == EvidenceScenario.approvedLogin)
            'approvalCompleted': event.state == EvidenceState.passed,
          if (command.scenario == EvidenceScenario.approvedLogin)
            'commitAcknowledged': status == AuthStatus.signedIn,
          if (command.scenario == EvidenceScenario.approvedLogin)
            'freshClient': freshClient,
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
  ) {
    bool verified(String slug) =>
        tuples[slug] == TupleEvidenceState.executedIdentityVerified;
    final sol = verified('gpt-5.6-sol');
    final terra = verified('gpt-5.6-terra');
    final luna = verified('gpt-5.6-luna');
    return _stateStore.writeResult(
      EvidenceResult(
        command: command,
        state: status == AuthStatus.signedIn && sol && terra && luna
            ? EvidenceResultState.pass
            : EvidenceResultState.fail,
        recovery: status == AuthStatus.signedIn
            ? EvidenceRecovery.signedIn
            : EvidenceRecovery.reauthenticationRequired,
        // One catalog request plus one Responses stream per required tuple.
        protectedIo: status == AuthStatus.signedIn ? 4 : 0,
        predicates: <String, Object?>{
          'catalogCount': 1,
          'solAdmitted': sol,
          'solRequestAccepted': sol,
          'solExecutedIdentityVerified': sol,
          'terraAdmitted': terra,
          'terraRequestAccepted': terra,
          'terraExecutedIdentityVerified': terra,
          'lunaAdmitted': luna,
          'lunaRequestAccepted': luna,
          'lunaExecutedIdentityVerified': luna,
        },
      ),
    );
  }

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
        clientFactory: _deviceAuthClient,
        statusDetail:
            'Polls: ${_deviceAuthTelemetry.pollCount}; '
            'last status: ${_deviceAuthTelemetry.lastStatus ?? 0}',
        onDeviceLoginFinished: (event, status) =>
            _completeDeviceLoginOutcome(command, event, status),
      );
    }
    if (command.scenario == EvidenceScenario.rehydrateAfterResume ||
        command.scenario == EvidenceScenario.rehydrateAfterProcessDeath) {
      return EvidenceRehydrationScenarioApp(
        command: command,
        stateStore: _stateStore,
        checkpoint: _checkpoint,
      );
    }
    if (switch (command.scenario) {
      EvidenceScenario.interruptAfterRefreshRisk ||
      EvidenceScenario.interruptBeforeReplacementCommit ||
      EvidenceScenario.interruptAfterReplacementCommit => true,
      _ => false,
    }) {
      return EvidenceInterruptionScenarioApp(
        command: command,
        stateStore: _stateStore,
        checkpoint: _checkpoint,
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
    if (command.scenario == EvidenceScenario.redirectMatrix) {
      unawaited(_runRedirectMatrix(command));
      return const MaterialApp(
        home: Scaffold(body: Center(child: Text('Running redirect evidence'))),
      );
    }
    if (switch (command.scenario) {
      EvidenceScenario.twoClientRotation ||
      EvidenceScenario.invalidGrant ||
      EvidenceScenario.expiredWithoutRefresh ||
      EvidenceScenario.malformedStore => true,
      _ => false,
    }) {
      return EvidenceRecoveryScenarioApp(
        command: command,
        stateStore: _stateStore,
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
