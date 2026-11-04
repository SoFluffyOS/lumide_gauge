import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_gauge/src/gauge_spec.dart';
import 'package:lumide_gauge/src/run_reporter.dart';
import 'package:lumide_gauge/src/run_selection.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

/// Gauge's output was captured from real runs of the fixture projects, with
/// the project folder replaced by `/project`.
void main() {
  const root = '/project';

  GaugeRunReporter reporterFor(String fixture, {List<String>? output}) {
    final fixtureRoot = 'test/fixtures/$fixture';
    final concepts = [
      for (final file in Directory('$fixtureRoot/specs').listSync())
        if (file.path.endsWith('.cpt'))
          ...parseConcepts(
            path.join(root, 'specs', path.basename(file.path)),
            File(file.path).readAsStringSync(),
          ),
    ];
    return GaugeRunReporter(
      projectRoot: root,
      concepts: concepts,
      onOutput: output?.add,
      loadSpec: (file) async {
        final local = path.join(fixtureRoot, path.relative(file, from: root));
        return parseSpec(file, await File(local).readAsString());
      },
    );
  }

  Future<Map<String, LumideTestResult>> replay(
    GaugeRunReporter reporter,
    String fixture,
  ) async {
    final lines = File('test/fixtures/$fixture/run.jsonl').readAsLinesSync();
    for (final line in lines) {
      await reporter.addLine(line);
    }
    reporter.finish();
    return {for (final result in reporter.takePending()) result.id: result};
  }

  const example = '/project/specs/example.spec';
  const second = '/project/specs/second.spec';
  const concept = '/project/specs/vowels.cpt';

  group('sample run', () {
    late GaugeRunReporter reporter;
    late Map<String, LumideTestResult> results;
    final output = <String>[];

    setUpAll(() async {
      reporter = reporterFor('sample', output: output);
      results = await replay(reporter, 'sample');
    });

    LumideTestResult result(String id) =>
        results[id] ?? fail('No result $id in ${results.keys}');

    test('shows specs with their outcome and location', () {
      expect(result(example).label, 'Specification Heading');
      expect(result(example).state, LumideTestState.passed);
      expect(result(example).uri, Uri.file(example).toString());
      expect(result(example).line, 1);
      expect(result(second).state, LumideTestState.failed);
      expect(result(second).parentId, isNull);
    });

    test('nests scenarios under their spec, on their heading line', () {
      final failing = result('$second:9');
      expect(failing.label, 'Failing scenario');
      expect(failing.parentId, second);
      expect(failing.line, 9);
      expect(failing.state, LumideTestState.failed);
      expect(failing.message, contains('Step: The word "gauge" has "4"'));
      expect(failing.message, contains('AssertionError'));
      expect(failing.durationMs, isNotNull);
    });

    test(
        'marks the failing step, steps before it passed, after it '
        'skipped', () {
      final failing = result('$second:9/13');
      expect(failing.label, 'The word "gauge" has "4" vowels.');
      expect(failing.parentId, '$second:9');
      expect(failing.state, LumideTestState.failed);
      expect(failing.uri, Uri.file(second).toString());
      expect(failing.line, 13);
      expect(failing.message, contains('Exception occurred'));
      expect(failing.message, contains('step_impl.py", line 16'));
      expect(result('$second:9/14').state, LumideTestState.skipped);
    });

    test('runs context steps with each scenario', () {
      final context = result('$example:13/11');
      expect(context.label, 'Vowels in English language are "aeiou".');
      expect(context.state, LumideTestState.passed);
      expect(result('$example:20/11').state, LumideTestState.passed);
      expect(result('$example:20/26').label, 'Almost all words have vowels');
    });

    test('shows a skipped scenario with the reason', () {
      final skipped = result('$second:16');
      expect(skipped.state, LumideTestState.skipped);
      expect(
        skipped.message,
        'Step implementation not found: This step has no implementation',
      );
      final step = result('$second:16/18');
      expect(step.state, LumideTestState.skipped);
      expect(step.message, 'Step implementation not found');
    });

    test('nests concept steps under the concept, in the concept file', () {
      final call = result('$second:5/7');
      expect(call.label, 'Check gauge vowels');
      expect(call.state, LumideTestState.passed);
      final inner = result('$second:5/7/vowels.cpt:3');
      expect(inner.parentId, '$second:5/7');
      expect(inner.uri, Uri.file(concept).toString());
      expect(inner.line, 3);
      expect(inner.state, LumideTestState.passed);
    });

    test('shows each table row under its scenario', () {
      expect(result('$second:20').state, LumideTestState.failed);
      final first = result('$second:20#0');
      expect(first.label, 'Row 1: Word = Gauge, Count = 3');
      expect(first.parentId, '$second:20');
      expect(first.state, LumideTestState.passed);
      final row = result('$second:20#1');
      expect(row.label, 'Row 2: Word = Snap, Count = 2');
      expect(row.state, LumideTestState.failed);
      final step = result('$second:20#1/27');
      expect(step.label, 'The word <Word> has <Count> vowels.');
      expect(step.state, LumideTestState.failed);
      expect(result('$second:20#0/27').state, LumideTestState.passed);
    });

    test('counts scenarios like Gauge does', () {
      // Gauge: 5 executed, 3 passed, 2 failed, 1 skipped; table rows are
      // counted one by one here.
      expect(reporter.summary, '4 passed, 2 failed, 1 skipped');
      expect(reporter.hasFailures, isTrue);
    });

    test('sends Gauge messages to the output', () {
      expect(output, contains('Python: 3.14.4'));
      expect(
        output,
        contains('Scenarios:\t5 executed\t3 passed\t2 failed\t1 skipped'),
      );
    });

    test('knows what to run for each result', () {
      expect(reporter.targetOf(second), const GaugeTarget(second));
      expect(
        reporter.targetOf('$second:9'),
        const GaugeTarget(second, line: 9),
      );
      expect(
        reporter.targetOf('$second:20#1/27'),
        const GaugeTarget(second, line: 20),
      );
      expect(reporter.labelOf('$second:9/13'), 'Failing scenario');
    });
  });

  group('edge run', () {
    late Map<String, LumideTestResult> results;
    const edge = '/project/specs/edge.spec';

    setUpAll(() async {
      results = await replay(reporterFor('edge'), 'edge');
    });

    test('reads setext headings', () {
      expect(results[edge]?.label, 'Edge spec');
      expect(results['$edge:6']?.label, 'Failing with teardown');
    });

    test('runs teardown steps after a failing step', () {
      expect(results['$edge:6/4']?.state, LumideTestState.passed);
      expect(results['$edge:6/9']?.state, LumideTestState.failed);
      expect(results['$edge:6/10']?.state, LumideTestState.skipped);
      expect(results['$edge:6/19']?.state, LumideTestState.passed);
    });

    test('skips every step when a before scenario hook fails', () {
      final scenario = results['$edge:12']!;
      expect(scenario.state, LumideTestState.failed);
      expect(
          scenario.message,
          startsWith('Before Scenario failed: hook '
              'exploded'));
      for (final step in ['4', '16', '19']) {
        expect(results['$edge:12/$step']?.state, LumideTestState.skipped);
      }
    });
  });

  group('events', () {
    late GaugeRunReporter reporter;
    final output = <String>[];

    setUp(() {
      output.clear();
      reporter = GaugeRunReporter(
        projectRoot: root,
        onOutput: output.add,
        loadSpec: (file) async => parseSpec(file, '''
# Spec
## One
* First "a"
* Second
* Third
'''),
      );
    });

    Future<void> send(Map<String, Object?> event) =>
        reporter.addLine(jsonEncode(event));

    Future<void> start() async {
      await send({
        'type': 'specStart',
        'id': 'specs/a.spec',
        'name': 'Spec',
        'filename': 'specs/a.spec',
        'line': 1,
      });
      await send({
        'type': 'scenarioStart',
        'id': 'specs/a.spec:2',
        'parentId': 'specs/a.spec',
        'name': 'One',
        'filename': 'specs/a.spec',
        'line': 2,
        'result': {'time': 0},
      });
    }

    test('shows a scenario running with its steps queued', () async {
      await start();
      final results = {for (final r in reporter.takePending()) r.id: r};
      expect(results['specs/a.spec']?.state, LumideTestState.running);
      expect(
        results['specs/a.spec']?.uri,
        Uri.file('/project/specs/a.spec').toString(),
      );
      expect(results['specs/a.spec:2']?.state, LumideTestState.running);
      expect(results['specs/a.spec:2/3']?.state, LumideTestState.queued);
    });

    test('uses the line Gauge reports for a failing step', () async {
      await start();
      await send({
        'type': 'scenarioEnd',
        'id': 'specs/a.spec:2',
        'parentId': 'specs/a.spec',
        'filename': 'specs/a.spec',
        'line': 2,
        'result': {
          'status': 'fail',
          'time': 3,
          'errors': [
            {
              'text': 'Something else',
              'filename': 'specs/a.spec',
              'message': 'boom',
              'lineNo': '4',
              'stackTrace': '',
            },
          ],
        },
      });
      final results = {for (final r in reporter.takePending()) r.id: r};
      expect(results['specs/a.spec:2/3']?.state, LumideTestState.passed);
      expect(results['specs/a.spec:2/4']?.state, LumideTestState.failed);
      expect(results['specs/a.spec:2/4']?.message, 'boom');
      expect(results['specs/a.spec:2/5']?.state, LumideTestState.skipped);
    });

    test('keeps going after a failure Gauge continued from', () async {
      await start();
      await send({
        'type': 'scenarioEnd',
        'id': 'specs/a.spec:2',
        'parentId': 'specs/a.spec',
        'filename': 'specs/a.spec',
        'line': 2,
        'result': {
          'status': 'fail',
          'errors': [
            {'text': 'First "b"', 'message': 'one'},
            {'text': 'Third', 'message': 'two'},
          ],
        },
      });
      final results = {for (final r in reporter.takePending()) r.id: r};
      expect(results['specs/a.spec:2/3']?.state, LumideTestState.failed);
      expect(results['specs/a.spec:2/4']?.state, LumideTestState.passed);
      expect(results['specs/a.spec:2/5']?.state, LumideTestState.failed);
    });

    test('marks what still runs as skipped when stopped', () async {
      await start();
      reporter.takePending();
      reporter.finish(stopped: true);
      final results = reporter.takePending();
      expect(results, isNotEmpty);
      for (final result in results) {
        expect(result.state, LumideTestState.skipped);
        expect(result.message, 'Stopped before it finished.');
      }
    });

    test('shows suite hook failures', () async {
      await send({
        'type': 'suiteEnd',
        'result': {
          'status': 'fail',
          'beforeHookFailure': {
            'text': 'Before Suite',
            'message': 'no browser',
            'stackTrace': 'at setup',
          },
        },
      });
      final result = reporter.takePending().single;
      expect(result.label, 'Before Suite hook');
      expect(result.state, LumideTestState.failed);
      expect(result.message, 'Before Suite failed: no browser\nat setup');
    });

    test('passes lines that are not events to the output', () async {
      await reporter.addLine('panic: something');
      await reporter.addLine('{not json');
      expect(output, ['panic: something', '{not json']);
      expect(reporter.summary, 'No scenarios ran');
    });
  });
}
