import 'dart:async';
import 'dart:io' as io;

import 'package:lumide_api/lumide_api.dart';

/// A running `gauge` process.
abstract interface class GaugeProcess {
  int get pid;

  /// Decoded stdout chunks. Single subscription.
  Stream<String> get stdout;

  /// Decoded stderr chunks. Single subscription.
  Stream<String> get stderr;

  Future<int> get exitCode;

  /// Stops Gauge and the language runner it started. [force] kills them
  /// immediately.
  Future<void> stop({bool force = false});
}

/// Starts `gauge` with arguments in a working directory.
typedef GaugeLauncher = Future<GaugeProcess> Function(
  List<String> arguments,
  String workingDirectory,
);

/// Starts Gauge through Lumide (`shell.spawn`), so it runs with the
/// plugin's shell permission and Lumide's environment.
///
/// Output can arrive before `spawn` returns the pid, so while a spawn is in
/// flight, output for unknown pids is held and replayed once claimed.
class HostGaugeLauncher {
  HostGaugeLauncher(
    this._shell, {
    required this.command,
    this.exitGrace = const Duration(milliseconds: 100),
  });

  static const _maxHeldEvents = 1000;

  final LumideShell _shell;

  /// The `gauge` executable, a name on PATH or a path.
  String command;

  /// How long output is still accepted after the exit notification, since
  /// Lumide can report the exit before the last output chunk.
  final Duration exitGrace;

  final Map<int, _HostGaugeProcess> _processes = {};
  final Map<int, List<_HostEvent>> _held = {};
  final List<LumideDisposable> _listeners = [];
  int _spawnsInFlight = 0;
  int _heldEventCount = 0;

  Future<GaugeProcess> start(
    List<String> arguments,
    String workingDirectory,
  ) async {
    _listen();
    _spawnsInFlight++;
    try {
      final pid = await _shell.spawn(
        command,
        arguments,
        workingDirectory: workingDirectory,
      );
      final process = _HostGaugeProcess(pid, _shell, exitGrace);
      _processes[pid] = process;
      for (final event in _held.remove(pid) ?? const <_HostEvent>[]) {
        _dispatch(process, event);
      }
      return process;
    } finally {
      _spawnsInFlight--;
      if (_spawnsInFlight == 0) {
        _held.clear();
        _heldEventCount = 0;
      }
    }
  }

  void dispose() {
    for (final listener in _listeners) {
      listener.dispose();
    }
    _listeners.clear();
    _held.clear();
    for (final process in _processes.values.toList()) {
      process._finish(-1);
    }
    _processes.clear();
  }

  void _listen() {
    if (_listeners.isNotEmpty) return;
    _listeners
      ..add(_shell.onStdout((pid, data) => _route(pid, _HostEvent(data))))
      ..add(_shell.onStderr(
          (pid, data) => _route(pid, _HostEvent(data, isStderr: true))))
      ..add(_shell.onExit((pid, code) => _route(pid, _HostEvent.exit(code))));
  }

  void _route(int pid, _HostEvent event) {
    if (_processes[pid] case final process?) {
      _dispatch(process, event);
      return;
    }
    final canHold = _spawnsInFlight > 0 && _heldEventCount < _maxHeldEvents;
    if (!canHold) return;
    _held.putIfAbsent(pid, () => []).add(event);
    _heldEventCount++;
  }

  void _dispatch(_HostGaugeProcess process, _HostEvent event) {
    switch (event) {
      case _HostEvent(exitCode: final code?):
        unawaited(
          process
              ._exit(code)
              .whenComplete(() => _processes.remove(process.pid)),
        );
      case _HostEvent(isStderr: true, :final data):
        process._addStderr(data);
      case _HostEvent(:final data):
        process._addStdout(data);
    }
  }
}

class _HostGaugeProcess implements GaugeProcess {
  _HostGaugeProcess(this.pid, this._shell, this._exitGrace);

  @override
  final int pid;
  final LumideShell _shell;
  final Duration _exitGrace;
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();
  final _exitCode = Completer<int>();

  @override
  Stream<String> get stdout => _stdout.stream;

  @override
  Stream<String> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> stop({bool force = false}) async {
    if (_exitCode.isCompleted) return;
    // Gauge does not stop its language runner when it is killed.
    await killDescendants(pid, force: force);
    try {
      await _shell.kill(
        pid,
        signal: switch (force) {
          true => LumideProcessSignal.kill,
          false => LumideProcessSignal.terminate,
        },
      );
    } catch (_) {
      // The process already exited or Lumide stopped tracking it.
    }
  }

  void _addStdout(String data) {
    if (!_stdout.isClosed) _stdout.add(data);
  }

  void _addStderr(String data) {
    if (!_stderr.isClosed) _stderr.add(data);
  }

  Future<void> _exit(int code) async {
    if (_exitCode.isCompleted) return;
    await Future<void>.delayed(_exitGrace);
    _finish(code);
  }

  void _finish(int code) {
    if (_exitCode.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exitCode.complete(code);
  }
}

class _HostEvent {
  const _HostEvent(this.data, {this.isStderr = false}) : exitCode = null;

  const _HostEvent.exit(int this.exitCode)
      : data = '',
        isStderr = false;

  final String data;
  final bool isStderr;
  final int? exitCode;
}

/// Stops the processes [pid] started, such as the language runner Gauge
/// starts, which keeps running when Gauge is killed.
Future<void> killDescendants(int pid, {bool force = false}) async {
  try {
    if (io.Platform.isWindows) {
      // taskkill /T stops the whole tree, Gauge included.
      await io.Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      return;
    }
    final signal = switch (force) {
      true => io.ProcessSignal.sigkill,
      false => io.ProcessSignal.sigterm,
    };
    for (final child in await _descendants(pid)) {
      io.Process.killPid(child, signal);
    }
  } catch (_) {
    // pgrep or taskkill is missing; Gauge itself is still stopped.
  }
}

/// [pid]'s descendants, deepest first.
Future<List<int>> _descendants(int pid, [int depth = 0]) async {
  if (depth > 8) return const [];
  final result = await io.Process.run('pgrep', ['-P', '$pid']);
  final children = [
    for (final line in '${result.stdout}'.split('\n'))
      if (int.tryParse(line.trim()) case final child?) child,
  ];
  return [
    for (final child in children) ...[
      ...await _descendants(child, depth + 1),
      child,
    ],
  ];
}
