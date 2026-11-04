import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_gauge/src/constants.dart';
import 'package:lumide_gauge/src/gauge_process.dart';
import 'package:lumide_gauge/src/gauge_projects.dart';
import 'package:lumide_gauge/src/gauge_spec.dart';
import 'package:lumide_gauge/src/run_reporter.dart';
import 'package:lumide_gauge/src/run_selection.dart';
import 'package:path/path.dart' as path;

/// Runs `gauge run --machine-readable` and shows results in Lumide's Tests
/// pane.
///
/// One run per Gauge project at a time: Gauge keeps the last run's state
/// (for `--failed`) and reports in the project. Each run title writes to
/// its own output channel, and recent runs are remembered so the Tests pane
/// can run them, or specs and scenarios inside them, again.
class GaugeTestRunService {
  GaugeTestRunService(
    this.context, {
    required this.launch,
    required this.ensureGauge,
    this.log,
    this.flushInterval = const Duration(milliseconds: 100),
  });

  /// Runs remembered for rerunning from the Tests pane.
  static const maxRememberedRuns = 10;

  /// Output channels kept for reuse by later runs with the same title.
  static const maxOutputChannels = 10;

  /// Concept files read to show concepts' steps.
  static const maxConceptFiles = 500;

  final LumideContext context;
  final GaugeLauncher launch;

  /// Returns whether Gauge is installed, telling the user how to install
  /// it when it is not.
  final Future<bool> Function() ensureGauge;
  final void Function(String message)? log;
  final Duration flushInterval;

  final Map<String, _ActiveRun> _active = {};
  final Map<String, _RunRecord> _records = {};
  final Map<String, LumideOutputChannel> _channels = {};
  String? _lastTags;

  bool get isRunning => _active.isNotEmpty;

  /// Runs every spec of the project of the active file or menu item, or of
  /// the first Gauge project in the workspace.
  Future<void> runAll([Map<String, dynamic>? args]) async {
    final root = await _rootFor(_pathFromArgs(args) ?? await _activePath());
    if (root == null) return _noProject();
    await _start(const GaugeInvocation(), root, requestId: _requestIdOf(args));
  }

  /// Runs the spec file (or folder of specs) from a menu, or the active
  /// spec.
  Future<void> runSpec([Map<String, dynamic>? args]) async {
    final target = _pathFromArgs(args) ?? await _activePath();
    if (target == null || !_isSpecPath(target)) {
      await _warn('Open a Gauge spec to run it.');
      return;
    }
    final root = await _rootFor(target);
    if (root == null) return _noProject();
    await _start(
      GaugeInvocation(targets: [GaugeTarget(target)]),
      root,
      requestId: _requestIdOf(args),
    );
  }

  /// Runs the scenario at `line` (1-based) of the spec in `path`, or at the
  /// cursor in the active spec.
  Future<void> runScenario([Map<String, dynamic>? args]) async {
    final file = _pathFromArgs(args) ?? await _activePath();
    if (file == null || path.extension(file) != '.spec') {
      await _warn('Open a Gauge spec and put the cursor in a scenario.');
      return;
    }
    final line = switch (args?['line']) {
      final int value => value,
      _ => await _cursorLine(),
    };
    final GaugeSpec spec;
    try {
      spec = parseSpec(file, await _documentText(file));
    } catch (error) {
      log?.call('Could not read $file: $error');
      await _warn('Could not read ${path.basename(file)}.');
      return;
    }
    final scenario = switch (line) {
      final value? => spec.scenarioAt(value),
      null => null,
    };
    if (scenario == null) {
      await _warn('Put the cursor in a scenario to run it.');
      return;
    }
    final root = await _rootFor(file);
    if (root == null) return _noProject();
    await _start(
      GaugeInvocation(targets: [GaugeTarget(file, line: scenario.line)]),
      root,
      title: scenario.name,
      requestId: _requestIdOf(args),
    );
  }

  /// Runs the scenarios that failed in the project's last run.
  Future<void> runFailed([Map<String, dynamic>? args]) async {
    final root = await _rootFor(_pathFromArgs(args) ?? await _activePath());
    if (root == null) return _noProject();
    await _start(
      const GaugeInvocation(failedOnly: true),
      root,
      requestId: _requestIdOf(args),
    );
  }

  /// Asks for a tag expression and runs the specs and scenarios matching
  /// it, or runs `tags` when given.
  Future<void> runTags([Map<String, dynamic>? args]) async {
    final root = await _rootFor(_pathFromArgs(args) ?? await _activePath());
    if (root == null) return _noProject();
    final tags = switch (args?['tags']) {
      final String value when value.trim().isNotEmpty => value,
      _ => await context.window.showInputBox(
          title: 'Run Specs with Tags',
          prompt: 'A tag expression, such as: login & !slow',
          value: _lastTags,
        ),
    };
    if (tags == null || tags.trim().isEmpty) return;
    _lastTags = tags.trim();
    await _start(
      GaugeInvocation(tags: tags.trim()),
      root,
      requestId: _requestIdOf(args),
    );
  }

  /// Runs what a Gauge code lens names: `specs/a.spec` or
  /// `specs/a.spec:12`, in `arguments`.
  Future<void> runCodeLens([Map<String, dynamic>? args]) async {
    final value = switch (args?['arguments']) {
      [final String first, ...] => first,
      _ => args?['path'] ?? args?['uri'],
    };
    if (value is! String) return;
    final active = await _activePath();
    final base = switch (active) {
      final value? => await _rootFor(value),
      null => null,
    };
    final target = GaugeTarget.parse(value, root: base);
    if (target == null) return;
    final root = await _rootFor(target.file);
    if (root == null) return _noProject();
    final scenarioName = switch (target.line) {
      final line? => await _scenarioName(target.file, line),
      null => null,
    };
    await _start(
      GaugeInvocation(targets: [target]),
      root,
      title: scenarioName,
      requestId: _requestIdOf(args),
    );
  }

  /// Runs a remembered run again, or the specs and scenarios in it named
  /// by `testIds`.
  ///
  /// Called by Lumide's Tests pane with `{'runId': ..., 'testIds': [...]}`.
  Future<void> rerun([Map<String, dynamic>? args]) async {
    final runId = args?['runId'];
    final record = switch (runId) {
      final String id => _lookup(_records, id),
      _ => null,
    };
    if (record == null) {
      log?.call('Cannot rerun specs: unknown run $runId');
      return;
    }
    final testIds = [
      for (final id in args?['testIds'] as List? ?? const [])
        if (id is String) id,
    ];
    if (testIds.isEmpty) {
      await _start(
        record.invocation,
        record.root,
        title: record.title,
        requestId: _requestIdOf(args),
      );
      return;
    }
    final targets = [
      for (final id in testIds)
        if (record.targetOf(id) case final target?) target,
    ];
    if (targets.isEmpty) {
      log?.call('Cannot rerun unknown results $testIds');
      return;
    }
    final invocation = invocationFor(targets);
    final title = switch (testIds) {
      [final id] => record.labelOf(id),
      _ => null,
    };
    await _start(
      invocation,
      record.root,
      title: title,
      requestId: _requestIdOf(args),
    );
  }

  /// Stops the run named by `runId`, or every run without one.
  Future<void> stop([Map<String, dynamic>? args]) async {
    final runs = switch (args?['runId']) {
      final String runId => [
          if (_lookup(_active, runId) case final active?) active,
        ],
      _ => _active.values.toList(),
    };
    await Future.wait(runs.map(_stopRun));
  }

  Future<void> dispose() async {
    await stop();
    final channels = _channels.values.toList();
    _channels.clear();
    for (final channel in channels) {
      await _disposeChannel(channel);
    }
  }

  Future<void> _stopRun(_ActiveRun active) async {
    active.cancelled = true;
    await active.process.stop();
    const grace = Duration(seconds: 5);
    try {
      await active.done.future.timeout(grace);
    } on TimeoutException {
      await active.process.stop(force: true);
      await active.done.future.timeout(grace, onTimeout: () {});
    }
  }

  Future<void> _start(
    GaugeInvocation invocation,
    String root, {
    String? title,
    String? requestId,
  }) async {
    if (!await ensureGauge()) return;
    final runTitle = title ?? invocation.title(root);
    if (!await _stopRunInProject(root, runTitle)) return;

    final arguments = invocation.arguments(root);
    final channelName = _freeChannelName(runTitle);
    final output = await _outputChannel(channelName);

    final LumideTestRun testRun;
    try {
      testRun = await context.tests.createRun(
        title: runTitle,
        output: output,
        runCommand: cmdRerun,
        stopCommand: cmdStop,
        requestId: requestId,
      );
    } catch (error) {
      await _warn('Running specs requires a newer Lumide.');
      log?.call('Could not create a test run: $error');
      return;
    }

    final outputBuffer = <String>['\$ gauge ${arguments.join(' ')}'];
    final reporter = GaugeRunReporter(
      projectRoot: root,
      loadSpec: (file) async => parseSpec(file, await _documentText(file)),
      concepts: await _concepts(root),
      onOutput: outputBuffer.add,
    );
    _remember(
      testRun.id,
      _RunRecord(
        invocation: invocation,
        root: root,
        title: runTitle,
        reporter: reporter,
      ),
    );

    final GaugeProcess process;
    try {
      process = await launch(arguments, root);
    } catch (error) {
      outputBuffer.add('Could not start gauge: $error');
      await _writeOutput(output, outputBuffer);
      await testRun.end(summary: 'Could not start gauge: $error');
      log?.call('Could not start gauge: $error');
      return;
    }

    final active = _ActiveRun(
      root: root,
      channelName: channelName,
      process: process,
      testRun: testRun,
      reporter: reporter,
      output: output,
      outputBuffer: outputBuffer,
    );
    _active[testRun.id] = active;
    active.flushTimer = Timer.periodic(flushInterval, (_) => _flush(active));
    active.stdout =
        process.stdout.transform(const LineSplitter()).listen((line) {
      active.queue = active.queue.then((_) => reporter.addLine(line));
    });
    active.stderr = process.stderr.listen((text) {
      outputBuffer.add(text.trimRight());
    });
    unawaited(process.exitCode.then((code) => _finish(active, code)));
  }

  /// Asks to stop a run in the same project before starting another.
  /// Returns false when the user keeps it running.
  Future<bool> _stopRunInProject(String root, String title) async {
    final running = [
      for (final active in _active.values)
        if (active.root == root) active,
    ];
    if (running.isEmpty) return true;
    final bool confirmed;
    try {
      confirmed = await context.window.showConfirmDialog(
        'Specs are still running in this project. Stop them and run '
        '"$title"?',
        title: 'Stop and Run',
      );
    } catch (error) {
      log?.call('Could not confirm stopping specs: $error');
      return false;
    }
    if (!confirmed) return false;
    await Future.wait(running.map(_stopRun));
    return true;
  }

  Future<void> _finish(_ActiveRun active, int exitCode) async {
    active.flushTimer?.cancel();
    await active.stdout?.cancel();
    await active.stderr?.cancel();
    await active.queue;
    final reporter = active.reporter;
    reporter.finish(stopped: active.cancelled);

    final summary = switch ((active.cancelled, reporter.scenarioCount)) {
      (true, _) => 'Stopped. ${reporter.summary}',
      (false, 0) when exitCode != 0 =>
        'gauge exited with code $exitCode. See the output for details.',
      _ => reporter.summary,
    };
    active.outputBuffer.add(summary);
    await _flush(active);
    if (!active.cancelled && reporter.scenarioCount == 0 && exitCode != 0) {
      try {
        await active.output?.show(preserveFocus: true);
      } catch (_) {
        // The channel is gone; the summary still says what happened.
      }
    }
    try {
      await active.testRun.end(summary: summary);
    } catch (error) {
      log?.call('Could not end the test run: $error');
    }
    _records[active.testRun.id]?.compact();
    _active.remove(active.testRun.id);
    active.done.complete();
  }

  Future<void> _flush(_ActiveRun active) async {
    await _writeOutput(active.output, active.outputBuffer);
    final results = active.reporter.takePending();
    if (results.isEmpty) return;
    try {
      await active.testRun.update(results);
    } catch (error) {
      log?.call('Could not send test results: $error');
    }
  }

  Future<List<GaugeConcept>> _concepts(String root) async {
    final List<String> uris;
    try {
      uris = await context.workspace.findFiles(
        '**/*.cpt',
        maxResults: maxConceptFiles,
      );
    } catch (error) {
      log?.call('Could not find concepts: $error');
      return const [];
    }
    final concepts = <GaugeConcept>[];
    for (final uri in uris) {
      final file = _toPath(uri);
      if (!path.isWithin(root, file)) continue;
      try {
        concepts.addAll(parseConcepts(file, await context.fs.readString(file)));
      } catch (error) {
        log?.call('Could not read concept $file: $error');
      }
    }
    return concepts;
  }

  Future<String?> _scenarioName(String file, int line) async {
    try {
      return parseSpec(file, await _documentText(file)).scenarioAt(line)?.name;
    } catch (_) {
      return null;
    }
  }

  /// The editor's text when the file is open, so unsaved edits count, or
  /// the file's text.
  Future<String> _documentText(String file) async {
    try {
      final text =
          await context.editor.getDocumentText(Uri.file(file).toString());
      if (text != null) return text;
    } catch (_) {
      // Not open in an editor.
    }
    return context.fs.readString(file);
  }

  Future<String?> _rootFor(String? file) async {
    Future<String?> read(String file) async {
      try {
        return await context.fs.readString(file);
      } catch (_) {
        return null;
      }
    }

    if (file != null) {
      final root = await findGaugeRoot(file, read);
      if (root != null) return root;
    }
    try {
      for (final folder in await context.workspace.getWorkspaceFolders()) {
        final folderPath = _toPath(folder.uri);
        if (await isGaugeProject(folderPath, read)) return folderPath;
      }
    } catch (error) {
      log?.call('Could not list workspace folders: $error');
    }
    return null;
  }

  Future<void> _noProject() => _warn(
        'No Gauge project found. A Gauge project has a manifest.json with a '
        '"Language" key.',
      );

  Future<void> _warn(String message) async {
    try {
      await context.window.showMessage(
        message,
        title: 'Gauge',
        type: MessageType.warning,
      );
    } catch (error) {
      log?.call('Could not show "$message": $error');
    }
  }

  String _freeChannelName(String title) {
    final busy = {for (final active in _active.values) active.channelName};
    var name = '$channelGaugeSpecs: $title';
    for (var copy = 2; busy.contains(name); copy++) {
      name = '$channelGaugeSpecs: $title ($copy)';
    }
    return name;
  }

  /// Reuses and clears the channel last used by [name], or creates one.
  Future<LumideOutputChannel?> _outputChannel(String name) async {
    final existing = _channels.remove(name);
    if (existing != null) {
      _channels[name] = existing;
      try {
        await existing.clear();
      } catch (error) {
        log?.call('Could not clear spec output: $error');
      }
      return existing;
    }
    final LumideOutputChannel channel;
    try {
      channel = await context.window.createOutputChannel(name);
    } catch (error) {
      log?.call('Could not create the spec output channel: $error');
      return null;
    }
    _channels[name] = channel;
    await _evictChannels();
    return channel;
  }

  Future<void> _evictChannels() async {
    final busy = {for (final active in _active.values) active.channelName};
    final idle = [
      for (final name in _channels.keys)
        if (!busy.contains(name)) name,
    ];
    var excess = _channels.length - maxOutputChannels;
    for (final name in idle) {
      if (excess <= 0) return;
      final channel = _channels.remove(name);
      if (channel != null) await _disposeChannel(channel);
      excess--;
    }
  }

  Future<void> _disposeChannel(LumideOutputChannel channel) async {
    try {
      await channel.dispose();
    } catch (error) {
      log?.call('Could not dispose spec output: $error');
    }
  }

  Future<void> _writeOutput(
    LumideOutputChannel? output,
    List<String> buffer,
  ) async {
    if (buffer.isEmpty) return;
    final text = buffer.join('\n');
    buffer.clear();
    if (output == null) return;
    try {
      await output.appendLine(text);
    } catch (error) {
      log?.call('Could not write spec output: $error');
    }
  }

  void _remember(String runId, _RunRecord record) {
    _records.remove(runId);
    _records[runId] = record;
    while (_records.length > maxRememberedRuns) {
      _records.remove(_records.keys.first);
    }
  }

  /// Lumide may prefix run ids with the plugin id (`lumide_gauge:run-1`).
  T? _lookup<T>(Map<String, T> byRunId, String runId) {
    final direct = byRunId[runId];
    if (direct != null) return direct;
    final separator = runId.lastIndexOf(':');
    if (separator < 0) return null;
    return byRunId[runId.substring(separator + 1)];
  }

  static String? _requestIdOf(Map<String, dynamic>? args) =>
      switch (args?[LumideTests.requestIdArgument]) {
        final String requestId => requestId,
        _ => null,
      };

  static bool _isSpecPath(String file) => switch (path.extension(file)) {
        '.spec' || '.md' => true,
        '' => true,
        _ => false,
      };

  String? _pathFromArgs(Map<String, dynamic>? args) {
    if (_menuPath(args) case final menuPath?) return menuPath;
    final value = args?['path'] ?? args?['uri'];
    if (value is! String || value.isEmpty) return null;
    return _toPath(value);
  }

  /// The file or folder a context menu passed in `context`.
  static String? _menuPath(Map<String, dynamic>? args) {
    final menu = args?['context'];
    if (menu is! Map) return null;
    String? pathOf(Object? value) => switch (value) {
          {'path': final String value} when value.isNotEmpty => value,
          _ => null,
        };
    final tab = menu['tab'];
    return pathOf(menu['file']) ??
        pathOf(tab is Map ? tab['file'] : null) ??
        pathOf(menu['primary']) ??
        switch (menu['selectedPaths']) {
          [final String first, ...] when first.isNotEmpty => first,
          _ => null,
        } ??
        pathOf(menu['root']);
  }

  static String _toPath(String value) => switch (value.startsWith('file:')) {
        true => Uri.parse(value).toFilePath(),
        false => value,
      };

  Future<String?> _activePath() async {
    try {
      final uri = await context.editor.getActiveDocumentUri();
      if (uri == null || uri.isEmpty) return null;
      return _toPath(uri);
    } catch (_) {
      return null;
    }
  }

  /// The 1-based line of the active editor's cursor.
  Future<int?> _cursorLine() async {
    try {
      final selections = await context.editor.getSelections();
      return switch (selections.firstOrNull) {
        {'focus': {'line': final int line}} => line + 1,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
}

/// A run that can be started again from the Tests pane.
class _RunRecord {
  _RunRecord({
    required this.invocation,
    required this.root,
    required this.title,
    required GaugeRunReporter reporter,
  }) : _reporter = reporter;

  final GaugeInvocation invocation;
  final String root;
  final String title;
  GaugeRunReporter? _reporter;
  Map<String, GaugeTarget>? _targets;
  Map<String, String>? _labels;

  GaugeTarget? targetOf(String resultId) =>
      _targets?[resultId] ?? _reporter?.targetOf(resultId);

  String? labelOf(String resultId) =>
      _labels?[resultId] ?? _reporter?.labelOf(resultId);

  /// Keeps only targets and labels once the run ends.
  void compact() {
    final reporter = _reporter;
    if (reporter == null) return;
    _targets = reporter.targets();
    _labels = reporter.labels();
    _reporter = null;
  }
}

class _ActiveRun {
  _ActiveRun({
    required this.root,
    required this.channelName,
    required this.process,
    required this.testRun,
    required this.reporter,
    required this.output,
    required this.outputBuffer,
  });

  final String root;
  final String channelName;
  final GaugeProcess process;
  final LumideTestRun testRun;
  final GaugeRunReporter reporter;
  final LumideOutputChannel? output;
  final List<String> outputBuffer;
  final Completer<void> done = Completer<void>();
  Future<void> queue = Future.value();
  Timer? flushTimer;
  StreamSubscription<String>? stdout;
  StreamSubscription<String>? stderr;
  bool cancelled = false;
}
