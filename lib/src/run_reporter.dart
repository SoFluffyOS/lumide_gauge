import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_gauge/src/gauge_spec.dart';
import 'package:lumide_gauge/src/run_selection.dart';
import 'package:path/path.dart' as path;

/// Turns `gauge run --machine-readable` events into Tests pane results.
///
/// Specs are top-level results, scenarios nest under their spec, and the
/// rows of a table-driven scenario nest under the scenario. Steps nest under
/// the scenario (or row), with a concept's steps under the concept.
///
/// Gauge reports results per scenario, not per step, so step states are
/// worked out from the scenario's errors: steps before the last failing step
/// passed, and steps after it did not run. Steps that run before and after
/// each scenario (context and teardown steps) are shown with it, like Gauge
/// runs them.
///
/// Gauge's messages, and lines that are not events, go to [onOutput].
class GaugeRunReporter {
  GaugeRunReporter({
    required this.projectRoot,
    required this.loadSpec,
    this.concepts = const [],
    this.onOutput,
  });

  final String projectRoot;

  /// Reads and parses the spec at an absolute path, or null when it cannot.
  final Future<GaugeSpec?> Function(String path) loadSpec;

  /// The project's concepts, to show the steps of the concepts a scenario
  /// uses.
  final List<GaugeConcept> concepts;
  final void Function(String text)? onOutput;

  final List<LumideTestResult> _pending = [];
  final Map<String, LumideTestResult> _results = {};
  final Map<String, GaugeTarget> _targets = {};
  final Map<String, String> _labels = {};
  final Map<String, Future<GaugeSpec?>> _specs = {};
  final Map<String, List<_StepNode>> _steps = {};
  final Map<String, Map<String, ({LumideTestState state, int ms})>> _rows = {};
  final Map<String, int> _specDurations = {};
  int _passed = 0;
  int _failed = 0;
  int _skipped = 0;

  /// Results changed since the last call.
  List<LumideTestResult> takePending() {
    final results = List.of(_pending);
    _pending.clear();
    return results;
  }

  /// Scenario counts, such as `3 passed, 1 failed`.
  String get summary {
    if (_passed + _failed + _skipped == 0) return 'No scenarios ran';
    return [
      '$_passed passed',
      if (_failed > 0) '$_failed failed',
      if (_skipped > 0) '$_skipped skipped',
    ].join(', ');
  }

  bool get hasFailures => _failed > 0;

  int get scenarioCount => _passed + _failed + _skipped;

  /// The spec or scenario behind a result id, to run it again.
  GaugeTarget? targetOf(String resultId) => _targets[resultId];

  /// Every result id this reporter knows, with its target.
  Map<String, GaugeTarget> targets() => Map.of(_targets);

  /// The name of the spec or scenario a result id runs.
  String? labelOf(String resultId) => _labels[resultId];

  /// Every result id this reporter knows, with [labelOf] it.
  Map<String, String> labels() => Map.of(_labels);

  /// Handles one stdout line.
  Future<void> addLine(String line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    final event = _decode(trimmed);
    if (event == null) {
      onOutput?.call(line);
      return;
    }
    switch (event['type']) {
      case 'out':
        onOutput?.call(_string(event['message']) ?? '');
      case 'specStart':
        await _onSpecStart(event);
      case 'scenarioStart':
        await _onScenarioStart(event);
      case 'scenarioEnd':
        await _onScenarioEnd(event);
      case 'specEnd':
        _onSpecEnd(event);
      case 'suiteEnd':
        _onSuiteEnd(event);
    }
  }

  /// Ends results still running, as when the run was stopped.
  void finish({bool stopped = false}) {
    for (final result in _results.values.toList()) {
      if (result.state != LumideTestState.running &&
          result.state != LumideTestState.queued) {
        continue;
      }
      _emit(
        result,
        state: LumideTestState.skipped,
        message: switch (stopped) {
          true => 'Stopped before it finished.',
          false => result.message,
        },
      );
    }
  }

  static Map<String, dynamic>? _decode(String line) {
    if (!line.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic> && decoded['type'] is String) {
        return decoded;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  String _absolute(String file) => switch (path.isAbsolute(file)) {
        true => path.normalize(file),
        false => path.normalize(path.join(projectRoot, file)),
      };

  String? _fileOf(Map<String, dynamic> event) {
    final file = _string(event['filename']);
    if (file == null || file.isEmpty) return null;
    return _absolute(file);
  }

  Future<GaugeSpec?> _spec(String file) => _specs.putIfAbsent(file, () async {
        try {
          return await loadSpec(file);
        } catch (_) {
          return null;
        }
      });

  Future<void> _onSpecStart(Map<String, dynamic> event) async {
    final file = _fileOf(event);
    final id = _string(event['id']) ?? file;
    if (id == null) return;
    final spec = switch (file) {
      final value? => await _spec(value),
      null => null,
    };
    if (file != null) _targets[id] = GaugeTarget(file);
    _specDurations[id] = 0;
    final label = _labelOf(_string(event['name']), spec?.name, file);
    _labels[id] = label;
    _emitNew(
      id: id,
      label: label,
      state: LumideTestState.running,
      file: file,
      line: _int(event['line']),
    );
  }

  Future<void> _onScenarioStart(Map<String, dynamic> event) async {
    final ids = _scenarioIds(event);
    if (ids == null) return;
    final file = _fileOf(event);
    final line = _int(event['line']);
    if (!_results.containsKey(ids.specId)) {
      _emitNew(
        id: ids.specId,
        label: _labelOf(null, null, file),
        state: LumideTestState.running,
        file: file,
      );
    }
    if (file != null) {
      _targets[ids.specId] ??= GaugeTarget(file);
      _targets[ids.scenarioId] = GaugeTarget(file, line: line);
    }
    final scenarioName = _string(event['name']) ?? 'Scenario';
    _labels[ids.scenarioId] = scenarioName;
    _emitNew(
      id: ids.scenarioId,
      parentId: ids.specId,
      label: scenarioName,
      state: LumideTestState.running,
      file: file,
      line: line,
    );
    if (ids.rowId case final rowId?) {
      if (file != null) _targets[rowId] = GaugeTarget(file, line: line);
      _labels[rowId] = scenarioName;
      _emitNew(
        id: rowId,
        parentId: ids.scenarioId,
        label: _rowLabel(event),
        state: LumideTestState.running,
        file: file,
        line: line,
      );
    }

    final spec = switch (file) {
      final value? => await _spec(value),
      null => null,
    };
    final parentId = ids.rowId ?? ids.scenarioId;
    final nodes = _stepNodes(spec, line, parentId);
    _steps[parentId] = nodes;
    for (final node in nodes) {
      _emitNode(node, parentId);
    }
    if (file != null) {
      for (final node in _flatten(nodes)) {
        _targets[node.id] = GaugeTarget(file, line: line);
        _labels[node.id] = scenarioName;
      }
    }
  }

  Future<void> _onScenarioEnd(Map<String, dynamic> event) async {
    final ids = _scenarioIds(event);
    if (ids == null) return;
    if (!_results.containsKey(ids.scenarioId) ||
        (ids.rowId != null && !_results.containsKey(ids.rowId))) {
      await _onScenarioStart(event);
    }
    final result = _map(event['result']) ?? const {};
    final state = _stateOf(_string(result['status']));
    final errors = [
      for (final error in _list(result['errors']))
        if (_map(error) case final value?) _GaugeError.fromJson(value),
    ];
    final beforeHook = switch (_map(result['beforeHookFailure'])) {
      final value? => _GaugeError.fromJson(value),
      null => null,
    };
    final afterHook = switch (_map(result['afterHookFailure'])) {
      final value? => _GaugeError.fromJson(value),
      null => null,
    };
    final durationMs = _int(result['time']);
    final message = _scenarioMessage(state, errors, beforeHook, afterHook);

    final parentId = ids.rowId ?? ids.scenarioId;
    final nodes = _steps.remove(parentId) ?? const [];
    _applyStepStates(nodes, state, errors, beforeHook);
    for (final node in nodes) {
      _emitNode(node, parentId);
    }

    switch (state) {
      case LumideTestState.passed:
        _passed++;
      case LumideTestState.failed:
        _failed++;
      default:
        _skipped++;
    }
    _specDurations.update(
      ids.specId,
      (total) => total + (durationMs ?? 0),
      ifAbsent: () => durationMs ?? 0,
    );

    if (ids.rowId case final rowId?) {
      _update(rowId, state: state, message: message, durationMs: durationMs);
      final rows = _rows.putIfAbsent(ids.scenarioId, () => {});
      rows[rowId] = (state: state, ms: durationMs ?? 0);
      _update(
        ids.scenarioId,
        state: _rollUp([for (final row in rows.values) row.state]),
        durationMs: rows.values.fold<int>(0, (sum, row) => sum + row.ms),
      );
      return;
    }
    _update(
      ids.scenarioId,
      state: state,
      message: message,
      durationMs: durationMs,
    );
  }

  void _onSpecEnd(Map<String, dynamic> event) {
    final id = _string(event['id']) ?? _fileOf(event);
    if (id == null || !_results.containsKey(id)) return;
    final result = _map(event['result']) ?? const {};
    final hooks = [
      if (_map(result['beforeHookFailure']) case final value?)
        _GaugeError.fromJson(value),
      if (_map(result['afterHookFailure']) case final value?)
        _GaugeError.fromJson(value),
    ];
    _update(
      id,
      state: _stateOf(_string(result['status'])),
      message: switch (hooks) {
        [] => null,
        _ => hooks.map(_hookMessage).join('\n\n'),
      },
      durationMs: _specDurations[id],
    );
  }

  void _onSuiteEnd(Map<String, dynamic> event) {
    final result = _map(event['result']) ?? const {};
    for (final (key, label) in const [
      ('beforeHookFailure', 'Before Suite hook'),
      ('afterHookFailure', 'After Suite hook'),
    ]) {
      final failure = _map(result[key]);
      if (failure == null) continue;
      _emitNew(
        id: 'suite:$key',
        label: label,
        state: LumideTestState.failed,
        message: _hookMessage(_GaugeError.fromJson(failure)),
      );
      _failed++;
    }
  }

  ({String specId, String scenarioId, String? rowId})? _scenarioIds(
    Map<String, dynamic> event,
  ) {
    final scenarioId = _string(event['id']);
    if (scenarioId == null) return null;
    final specId = _string(event['parentId']) ?? _fileOf(event) ?? scenarioId;
    final table = _map(_map(event['result'])?['table']);
    final rowIndex = _int(table?['rowIndex']);
    return (
      specId: specId,
      scenarioId: scenarioId,
      rowId: switch (table) {
        null => null,
        _ => '$scenarioId#${rowIndex ?? 0}',
      },
    );
  }

  /// The steps that run for the scenario on [line] of [spec].
  List<_StepNode> _stepNodes(GaugeSpec? spec, int? line, String parentId) {
    if (spec == null || line == null) return const [];
    final scenario = spec.scenarioOnLine(line) ?? spec.scenarioAt(line);
    if (scenario == null) return const [];
    return [
      for (final (group, steps) in [
        (_StepGroup.context, spec.contextSteps),
        (_StepGroup.scenario, scenario.steps),
        (_StepGroup.teardown, spec.teardownSteps),
      ])
        for (final step in steps)
          _node(step, spec.path, '$parentId/${step.line}', group, 0),
    ];
  }

  _StepNode _node(
    GaugeStep step,
    String file,
    String id,
    _StepGroup group,
    int depth,
  ) {
    final concept = switch (depth < _maxConceptDepth) {
      true => _conceptFor(step.text),
      false => null,
    };
    return _StepNode(
      id: id,
      step: step,
      file: file,
      group: group,
      children: [
        if (concept != null)
          for (final child in concept.steps)
            _node(
              child,
              concept.path,
              '$id/${path.basename(concept.path)}:${child.line}',
              group,
              depth + 1,
            ),
      ],
    );
  }

  static const _maxConceptDepth = 8;

  GaugeConcept? _conceptFor(String text) {
    final pattern = stepPattern(text);
    for (final concept in concepts) {
      if (stepPattern(concept.heading) == pattern) return concept;
    }
    return null;
  }

  /// Gives each step a state from its scenario's [state] and [errors].
  void _applyStepStates(
    List<_StepNode> nodes,
    LumideTestState state,
    List<_GaugeError> errors,
    _GaugeError? beforeHook,
  ) {
    final leaves = _leaves(nodes);
    if (leaves.isEmpty) return;
    for (final error in errors) {
      final leaf = _match(leaves, error);
      if (leaf == null) continue;
      leaf.error = error;
    }
    final matched = leaves.any((leaf) => leaf.error != null);

    if (state == LumideTestState.passed) {
      for (final leaf in leaves) {
        leaf.state = LumideTestState.passed;
      }
    } else if (state != LumideTestState.failed ||
        beforeHook != null ||
        !matched) {
      for (final leaf in leaves) {
        leaf.state = LumideTestState.skipped;
      }
    } else {
      _applyFailedStates(leaves);
    }
    for (final node in nodes) {
      _rollUpNode(node);
    }
  }

  /// Within each group of steps, Gauge stops at a failing step unless it
  /// may continue on failure, so steps up to the last failure ran and the
  /// rest did not. A failing context step skips the scenario's own steps;
  /// teardown steps always run.
  void _applyFailedStates(List<_StepNode> leaves) {
    var contextFailed = false;
    for (final group in _StepGroup.values) {
      final inGroup = [
        for (final leaf in leaves)
          if (leaf.group == group) leaf,
      ];
      final skipAll = group == _StepGroup.scenario && contextFailed;
      final lastFailure = inGroup.lastIndexWhere((leaf) => leaf.error != null);
      for (final (index, leaf) in inGroup.indexed) {
        if (leaf.error != null) {
          leaf.state = LumideTestState.failed;
        } else if (skipAll || index > lastFailure && lastFailure >= 0) {
          leaf.state = LumideTestState.skipped;
        } else {
          leaf.state = LumideTestState.passed;
        }
      }
      if (group == _StepGroup.context && lastFailure >= 0) {
        contextFailed = true;
      }
    }
  }

  /// The first step not yet matched that [error] is about: by line when
  /// Gauge reports one, then by text, then by text without parameters.
  _StepNode? _match(List<_StepNode> leaves, _GaugeError error) {
    final free = [
      for (final leaf in leaves)
        if (leaf.error == null) leaf,
    ];
    final line = int.tryParse(error.lineNo);
    if (line != null) {
      for (final leaf in free) {
        if (leaf.step.line == line &&
            (error.filename.isEmpty ||
                _absolute(error.filename) == leaf.file)) {
          return leaf;
        }
      }
    }
    final text = error.stepText;
    for (final matches in <bool Function(_StepNode)>[
      (leaf) => leaf.step.text == text,
      (leaf) => stepPattern(leaf.step.text) == stepPattern(text),
      (leaf) => looseStepPattern(leaf.step.text) == looseStepPattern(text),
    ]) {
      for (final leaf in free) {
        if (matches(leaf)) return leaf;
      }
    }
    return null;
  }

  void _rollUpNode(_StepNode node) {
    if (node.children.isEmpty) return;
    for (final child in node.children) {
      _rollUpNode(child);
    }
    final states = [for (final child in node.children) child.state];
    node.state = _rollUp(states);
  }

  static LumideTestState _rollUp(List<LumideTestState> states) {
    if (states.contains(LumideTestState.failed)) return LumideTestState.failed;
    if (states.contains(LumideTestState.errored)) {
      return LumideTestState.errored;
    }
    if (states.contains(LumideTestState.running) ||
        states.contains(LumideTestState.queued)) {
      return LumideTestState.running;
    }
    if (states.contains(LumideTestState.passed)) return LumideTestState.passed;
    return LumideTestState.skipped;
  }

  static List<_StepNode> _leaves(List<_StepNode> nodes) => [
        for (final node in nodes)
          if (node.children.isEmpty) node else ..._leaves(node.children),
      ];

  static List<_StepNode> _flatten(List<_StepNode> nodes) => [
        for (final node in nodes) ...[node, ..._flatten(node.children)],
      ];

  void _emitNode(_StepNode node, String parentId) {
    final message = switch (node.error) {
      final error? when node.children.isEmpty => error.details,
      _ => null,
    };
    _emitNew(
      id: node.id,
      parentId: parentId,
      label: node.step.text,
      state: node.state,
      file: node.file,
      line: node.step.line,
      message: message,
    );
    for (final child in node.children) {
      _emitNode(child, node.id);
    }
  }

  String? _scenarioMessage(
    LumideTestState state,
    List<_GaugeError> errors,
    _GaugeError? beforeHook,
    _GaugeError? afterHook,
  ) {
    final parts = [
      if (beforeHook != null) _hookMessage(beforeHook),
      for (final error in errors)
        switch (state) {
          LumideTestState.skipped => '${error.message}: ${error.text}',
          _ => [
              'Step: ${error.text}',
              if (error.details case final details? when details.isNotEmpty)
                details,
            ].join('\n'),
        },
      if (afterHook != null) _hookMessage(afterHook),
    ];
    if (parts.isEmpty) return null;
    return parts.join('\n\n');
  }

  static String _hookMessage(_GaugeError error) => [
        '${error.text} failed: ${error.message}',
        if (error.stackTrace.trim().isNotEmpty) error.stackTrace.trimRight(),
      ].join('\n');

  static String _rowLabel(Map<String, dynamic> event) {
    final table = _map(_map(event['result'])?['table']);
    final rowIndex = _int(table?['rowIndex']) ?? 0;
    final rows = [
      for (final line in (_string(table?['text']) ?? '').split('\n'))
        if (line.trim().startsWith('|') && !_isSeparator(line)) _cells(line),
    ];
    final title = 'Row ${rowIndex + 1}';
    if (rows.length < 2) return title;
    final header = rows.first;
    final values = rows[1];
    final cells = [
      for (var index = 0; index < values.length; index++)
        if (index < header.length) '${header[index]} = ${values[index]}',
    ];
    if (cells.isEmpty) return title;
    return '$title: ${cells.join(', ')}';
  }

  static List<String> _cells(String line) {
    var row = line.trim();
    if (row.startsWith('|')) row = row.substring(1);
    if (row.endsWith('|')) row = row.substring(0, row.length - 1);
    return [for (final cell in row.split('|')) cell.trim()];
  }

  static bool _isSeparator(String line) =>
      RegExp(r'^\s*\|?[\s\-|:]+\|?\s*$').hasMatch(line);

  String _labelOf(String? eventName, String? specName, String? file) {
    for (final name in [eventName, specName]) {
      if (name != null && name.trim().isNotEmpty) return name.trim();
    }
    if (file != null) return path.basename(file);
    return 'Spec';
  }

  static LumideTestState _stateOf(String? status) => switch (status) {
        'pass' => LumideTestState.passed,
        'fail' => LumideTestState.failed,
        'skip' => LumideTestState.skipped,
        _ => LumideTestState.errored,
      };

  void _emitNew({
    required String id,
    String? parentId,
    required String label,
    required LumideTestState state,
    String? file,
    int? line,
    String? message,
    int? durationMs,
  }) {
    _put(
      LumideTestResult(
        id: id,
        label: label,
        state: state,
        parentId: parentId,
        uri: switch (file) {
          final value? => Uri.file(value).toString(),
          null => null,
        },
        line: line,
        message: message,
        durationMs: durationMs,
      ),
    );
  }

  void _update(
    String id, {
    required LumideTestState state,
    String? message,
    int? durationMs,
  }) {
    final result = _results[id];
    if (result == null) return;
    _emit(result, state: state, message: message, durationMs: durationMs);
  }

  void _emit(
    LumideTestResult result, {
    required LumideTestState state,
    String? message,
    int? durationMs,
  }) {
    _put(
      LumideTestResult(
        id: result.id,
        label: result.label,
        state: state,
        parentId: result.parentId,
        uri: result.uri,
        line: result.line,
        message: message,
        durationMs: durationMs ?? result.durationMs,
      ),
    );
  }

  void _put(LumideTestResult result) {
    _results[result.id] = result;
    _pending.add(result);
  }

  static String? _string(Object? value) => switch (value) {
        final String text => text,
        _ => null,
      };

  static int? _int(Object? value) => switch (value) {
        final int number => number,
        final String text => int.tryParse(text),
        _ => null,
      };

  static Map<String, dynamic>? _map(Object? value) => switch (value) {
        final Map<String, dynamic> map => map,
        _ => null,
      };

  static List<Object?> _list(Object? value) => switch (value) {
        final List<Object?> list => list,
        _ => const [],
      };
}

enum _StepGroup { context, scenario, teardown }

class _StepNode {
  _StepNode({
    required this.id,
    required this.step,
    required this.file,
    required this.group,
    required this.children,
  });

  final String id;
  final GaugeStep step;
  final String file;
  final _StepGroup group;
  final List<_StepNode> children;
  LumideTestState state = LumideTestState.queued;
  _GaugeError? error;
}

/// An error in a `scenarioEnd` event, or a hook failure.
class _GaugeError {
  const _GaugeError({
    required this.text,
    required this.message,
    required this.filename,
    required this.lineNo,
    required this.stackTrace,
  });

  factory _GaugeError.fromJson(Map<String, dynamic> json) => _GaugeError(
        text: GaugeRunReporter._string(json['text']) ?? '',
        message: GaugeRunReporter._string(json['message']) ?? '',
        filename: GaugeRunReporter._string(json['filename']) ?? '',
        lineNo: '${json['lineNo'] ?? ''}',
        stackTrace: GaugeRunReporter._string(json['stackTrace']) ?? '',
      );

  static final _stepHook = RegExp(r'^(?:Before|After)Step hook for step: ');

  /// The step's text, also for a step hook failure.
  String get stepText => text.replaceFirst(_stepHook, '');

  final String text;
  final String message;
  final String filename;
  final String lineNo;
  final String stackTrace;

  /// The message and stack trace.
  String? get details {
    final parts = [
      if (_stepHook.hasMatch(text)) text,
      if (message.trim().isNotEmpty) message.trim(),
      if (stackTrace.trim().isNotEmpty) stackTrace.trimRight(),
    ];
    if (parts.isEmpty) return null;
    return parts.join('\n\n');
  }
}
