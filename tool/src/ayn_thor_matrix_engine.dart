import 'dart:convert';

import '../evidence_schema.dart';

enum MatrixStage {
  arguments('arguments'),
  artifactProvenance('artifact-provenance'),
  deviceSelection('device-selection'),
  physicalDevice('physical-device'),
  install('install'),
  installedDigest('installed-digest'),
  clearPreviousState('clear-previous-state'),
  redirectFixture('redirect-fixture'),
  writeCommand('write-command'),
  launch('launch'),
  finiteResult('finite-result'),
  commandConsumption('command-consumption'),
  validateResult('validate-result'),
  redirectValidation('redirect-validation'),
  durableCheckpoint('durable-checkpoint'),
  lifecycleResume('lifecycle-resume'),
  processRelaunch('process-relaunch');

  const MatrixStage(this.label);
  final String label;
}

enum CleanupStage {
  stop('cleanup-stop'),
  clear('cleanup-clear'),
  reverse('cleanup-reverse'),
  fixture('cleanup-fixture');

  const CleanupStage(this.label);
  final String label;
}

final class MatrixRunFailure implements Exception {
  const MatrixRunFailure({
    required this.primaryStage,
    this.cleanupStage,
    this.validationRejection,
  });

  final MatrixStage? primaryStage;
  final CleanupStage? cleanupStage;
  final RawEvidenceRejection? validationRejection;

  String get rejectionLabel =>
      primaryStage?.label ?? cleanupStage?.label ?? MatrixStage.arguments.label;
}

final class MatrixRunRequest {
  const MatrixRunRequest({
    required this.scenario,
    required this.packageCommit,
    required this.expectedDigest,
    required this.expectedApkBytes,
    required this.nonce,
    required this.resultTimeout,
  });

  final String scenario;
  final String packageCommit;
  final String expectedDigest;
  final int expectedApkBytes;
  final String nonce;
  final Duration resultTimeout;
}

abstract interface class MatrixRedirectFixture {
  Future<void> awaitReady();
  Future<List<Map<String, Object?>>> verify();
  Future<void> close();
}

abstract interface class AynThorMatrixAdapter {
  Future<void> requirePhysicalDevice();
  Future<void> install();
  Future<bool> installedDigestMatches(String expected, int expectedBytes);
  Future<void> clearTransientState();
  Future<MatrixRedirectFixture> startRedirectFixture();
  Future<void> reverseRedirectPort();
  Future<void> removeReverseRedirectPort();
  Future<void> writeCommand(String command);
  Future<void> launch();
  Future<String> processIdentity(Duration timeout);
  Future<void> waitForCheckpoint(Duration timeout);
  Future<void> backgroundAndResume();
  Future<String> waitForResult(Duration timeout);
  Future<bool> commandWasConsumed();
  Future<void> stop();
  Future<void> cleanupSettleDelay();
}

final class MatrixRunSuccess {
  const MatrixRunSuccess(this.safeJson);
  final String safeJson;
}

Future<MatrixRunSuccess> runAynThorMatrixEngine({
  required MatrixRunRequest request,
  required AynThorMatrixAdapter adapter,
  required void Function(String label) reportProgress,
}) async {
  MatrixStage stage = MatrixStage.physicalDevice;
  void progress(MatrixStage value) {
    stage = value;
    reportProgress(value.label);
  }

  try {
    progress(MatrixStage.physicalDevice);
    await adapter.requirePhysicalDevice();
    progress(MatrixStage.install);
    await adapter.install();
    progress(MatrixStage.installedDigest);
    if (!await adapter.installedDigestMatches(
      request.expectedDigest,
      request.expectedApkBytes,
    )) {
      throw StateError('installed APK does not match candidate');
    }
  } on Object {
    throw MatrixRunFailure(primaryStage: stage);
  }

  Object? primaryError;
  MatrixStage? primaryStage;
  RawEvidenceRejection? validationRejection;
  String? safeJson;
  var transientMayExist = false;
  var appMayRun = false;
  var reverseMayExist = false;
  MatrixRedirectFixture? fixture;

  try {
    progress(MatrixStage.clearPreviousState);
    transientMayExist = true;
    await adapter.clearTransientState();

    if (request.scenario == 'redirect-matrix') {
      progress(MatrixStage.redirectFixture);
      fixture = await adapter.startRedirectFixture();
      await fixture.awaitReady();
      reverseMayExist = true;
      await adapter.reverseRedirectPort();
    }

    final command = jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'scenario': request.scenario,
      'packageCommit': request.packageCommit,
      'flavor': 'evidence',
      'nonce': request.nonce,
    });
    progress(MatrixStage.writeCommand);
    transientMayExist = true;
    await adapter.writeCommand(command);
    progress(MatrixStage.launch);
    appMayRun = true;
    await adapter.launch();
    var processChanged = false;
    if (request.scenario == 'rehydrate-after-resume') {
      final originalProcess = await adapter.processIdentity(
        const Duration(seconds: 15),
      );
      progress(MatrixStage.durableCheckpoint);
      await adapter.waitForCheckpoint(request.resultTimeout);
      progress(MatrixStage.lifecycleResume);
      await adapter.backgroundAndResume();
      final resumedProcess = await adapter.processIdentity(
        const Duration(seconds: 15),
      );
      if (originalProcess != resumedProcess) {
        throw StateError('resume evidence process changed');
      }
    } else if (_interruptionScenarios.contains(request.scenario)) {
      final originalProcess = await adapter.processIdentity(
        const Duration(seconds: 15),
      );
      progress(MatrixStage.durableCheckpoint);
      await adapter.waitForCheckpoint(request.resultTimeout);
      progress(MatrixStage.processRelaunch);
      await adapter.stop();
      await adapter.launch();
      final replacementProcess = await adapter.processIdentity(
        const Duration(seconds: 15),
      );
      processChanged = originalProcess != replacementProcess;
      if (!processChanged) throw StateError('evidence process did not change');
    }
    progress(MatrixStage.finiteResult);
    var raw = await adapter.waitForResult(request.resultTimeout);
    if (processChanged) raw = _withProcessChanged(raw);
    progress(MatrixStage.commandConsumption);
    if (!await adapter.commandWasConsumed()) {
      throw StateError('evidence command was not consumed');
    }
    progress(MatrixStage.validateResult);
    validationRejection = EvidenceSchema.diagnoseRawResult(
      raw,
      scenario: request.scenario,
      packageCommit: request.packageCommit,
      nonce: request.nonce,
    );
    if (validationRejection != null) {
      throw StateError('finite evidence result is invalid');
    }
    final result = EvidenceSchema.validateRawResult(
      raw,
      scenario: request.scenario,
      packageCommit: request.packageCommit,
      nonce: request.nonce,
    );
    List<Map<String, Object?>>? redirects;
    if (fixture != null) {
      progress(MatrixStage.redirectValidation);
      redirects = await fixture.verify();
    }
    safeJson = jsonEncode(<String, Object?>{
      'device': 'ayn-thor',
      'scenario': request.scenario,
      'state': result['state'],
      'recovery': result['recovery'],
      'protectedIo': result['protectedIo'],
      'predicates': result['predicates'],
      if (result['category'] != null) 'category': result['category'],
      'redirects': ?redirects,
    });
  } on Object catch (error) {
    primaryError = error;
    primaryStage = stage;
  }

  CleanupStage? cleanupStage;
  Future<void> cleanup(
    CleanupStage candidate,
    Future<void> Function() action,
  ) async {
    reportProgress(candidate.label);
    try {
      await action();
    } on Object {
      cleanupStage ??= candidate;
    }
  }

  if (appMayRun) {
    await cleanup(CleanupStage.stop, () async {
      Object? stopError;
      try {
        await adapter.stop();
      } on Object catch (error) {
        stopError = error;
      }
      await adapter.cleanupSettleDelay();
      if (stopError != null) throw stopError;
    });
  }
  if (transientMayExist) {
    await cleanup(CleanupStage.clear, adapter.clearTransientState);
  }
  if (reverseMayExist) {
    await cleanup(CleanupStage.reverse, adapter.removeReverseRedirectPort);
  }
  if (fixture != null) {
    await cleanup(CleanupStage.fixture, fixture.close);
  }

  if (primaryError != null || cleanupStage != null) {
    throw MatrixRunFailure(
      primaryStage: primaryStage,
      cleanupStage: cleanupStage,
      validationRejection: validationRejection,
    );
  }
  return MatrixRunSuccess(safeJson!);
}

const _interruptionScenarios = <String>{
  'rehydrate-after-process-death',
  'interrupt-after-refresh-risk',
  'interrupt-before-replacement-commit',
  'interrupt-after-replacement-commit',
};

String _withProcessChanged(String raw) {
  final value = jsonDecode(raw);
  if (value is! Map || value['predicates'] is! Map) {
    throw const FormatException('invalid finite evidence result');
  }
  final result = Map<String, Object?>.from(value);
  final predicates = Map<String, Object?>.from(value['predicates']! as Map);
  predicates['processChanged'] = true;
  result['predicates'] = predicates;
  return jsonEncode(result);
}
