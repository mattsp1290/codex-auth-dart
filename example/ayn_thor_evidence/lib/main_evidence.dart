import 'package:codex_auth/codex_auth.dart';
import 'package:flutter/material.dart';

import 'build_provenance.dart';
import 'evidence_controller.dart';
import 'evidence_controls.dart';
import 'evidence_state_store.dart';
import 'main.dart';
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
    try {
      final command = await _stateStore.consumeCommand();
      if (command?.scenario == EvidenceScenario.localLogout) {
        await _runLocalLogout(command!);
      }
      if (mounted) setState(() => _command = command);
    } on Object {
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
      ),
    );
  }

  Future<void> _completeApprovedLogin(
    EvidenceCommand command,
    EvidenceEvent event,
    AuthStatus status,
  ) => _stateStore.writeResult(
    EvidenceResult(
      command: command,
      state:
          event.state == EvidenceState.passed && status == AuthStatus.signedIn
          ? EvidenceResultState.pass
          : EvidenceResultState.fail,
      recovery: status == AuthStatus.signedIn
          ? EvidenceRecovery.signedIn
          : EvidenceRecovery.reauthenticationRequired,
      protectedIo: 0,
      category: event.category?.name,
    ),
  );

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
    if (command.scenario == EvidenceScenario.approvedLogin) {
      return EvidenceHostApp(
        autoStartDeviceLogin: true,
        onDeviceLoginFinished: (event, status) =>
            _completeApprovedLogin(command, event, status),
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
