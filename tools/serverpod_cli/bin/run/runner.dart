import 'dart:async';
import 'dart:io';

import '../config_info/config_info.dart';
import '../generator/class_generator.dart';
import '../generator/config.dart';
import '../generator/dart_format.dart';
import '../generator/protocol_generator.dart';
import '../port_scanner/port_scanner.dart';
import '../util/process_killer_extension.dart';
import 'file_watcher.dart';

void performRun(bool verbose, bool runDocker) async {
  if (!config.load()) return;

  var configInfo = ConfigInfo('development');

  // TODO: Check if all required ports are available.

  // Do an initial serverpod generate.
  print('Running serverpod generate.');
  performGenerateClasses(verbose);
  await performGenerateProtocol(verbose);
  performDartFormat(verbose);

  // Generate continuously and hot reload.
  if (verbose) print('Starting up continuous generator');
  var serverRunner = _ServerRunner();
  var dockerRunner = _DockerRunner();
  var generatingAndReloading = false;

  bool protocolIsDirty = false;
  bool libIsDirty = false;

  var watcher = SourceFileWatcher(
    onChangedSourceFile: (changedPath, isProtocol) async {
      protocolIsDirty = protocolIsDirty || isProtocol;
      libIsDirty = true;

      // Batch process changes made within 500 ms.
      while (libIsDirty) {
        // The timer is used to group together changes if many files are saved
        // at the same time.
        Timer(const Duration(milliseconds: 500), () async {
          if (libIsDirty && !generatingAndReloading) {
            var protocolWasDirty = protocolIsDirty;

            generatingAndReloading = true;
            protocolIsDirty = false;
            libIsDirty = false;

            await _generateAndReload(
              verbose,
              protocolWasDirty,
              configInfo,
              serverRunner,
            );

            generatingAndReloading = false;
          }
        });
        await Future.delayed(const Duration(seconds: 1));
      }
    },
    onRemovedProtocolFile: (removedPath) async {
      // TODO: remove corresponding file
    },
  );

  // Start Docker.
  if (runDocker) {
    print('Starting Docker (for Postgres and Redis).');
    await dockerRunner.start(verbose);
  }

  // Verify that Postgres & Redis is up and running.
  print(
      'Waiting for Postgres on ${configInfo.config.dbHost}:${configInfo.config.dbPort}.');
  if (!await PortScanner.waitForPort(
    configInfo.config.dbHost,
    configInfo.config.dbPort,
    printProgress: true,
  )) {
    print('Failed to connect to Postgres.');
    return;
  }

  print(
      'Waiting for Redis on ${configInfo.config.redisHost}:${configInfo.config.redisPort}.');
  if (!await PortScanner.waitForPort(
    configInfo.config.redisHost,
    configInfo.config.redisPort,
    printProgress: true,
  )) {
    print('Failed to connect to Redis.');
    return;
  }

  // Start the server.
  print('Setup complete. Starting the server.');
  print('');
  await serverRunner.start();

  // Start watching the source directories.
  unawaited(watcher.watch(verbose));
}

Future<void> _generateAndReload(
  bool verbose,
  bool generate,
  ConfigInfo configInfo,
  _ServerRunner runner,
) async {
  if (generate) {
    try {
      performGenerateClasses(verbose);
    } catch (e, stackTrace) {
      print('Failed to generate classes: $e');
      print(stackTrace);
    }

    try {
      await performGenerateProtocol(verbose);
    } catch (e, stackTrace) {
      print('Failed to generate protocol: $e');
      print(stackTrace);
    }

    try {
      performDartFormat(verbose);
    } catch (e, stackTrace) {
      print('Failed to dart format: $e');
      print(stackTrace);
    }
  }

  try {
    // TODO: Implement real hot reload
    // TODO: Check if server code is valid before restarting.

    print('Stopping the server.');
    await runner.stop();
    await Future.delayed(const Duration(milliseconds: 500));

    // Start a new instance of the server
    print('Restarting the server.');
    await runner.start();
  } catch (e) {
    print('Failed hot reload: $e');
  }
}

class _ServerRunner {
  Process? _process;

  Future<void> start() async {
    assert(_process == null);
    _process = await Process.start(
      'dart',
      ['bin/main.dart'],
      mode: ProcessStartMode.inheritStdio,
      runInShell: true,
    );
  }

  Future<void> stop() async {
    // TODO: First attempt to use the shutdown command (needs to be fixed).

    assert(_process != null);
    await _process!.killAll();
    await _process!.exitCode;
    _process = null;
  }

  Future<int> exitCode() async {
    return _process!.exitCode;
  }
}

class _DockerRunner {
  Future<void> start(bool verbose) async {
    await Process.start(
      'docker-compose',
      ['up', '--build'],
    );

    // TODO: Check if it is possible to also pipe docker output to stdout.
    // if (verbose) {
    //   unawaited(stdout.addStream(process.stdout));
    //   unawaited(stderr.addStream(process.stderr));
    // }
  }
}
