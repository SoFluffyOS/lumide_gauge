import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_gauge/src/constants.dart';
import 'package:lumide_gauge/src/gauge_process.dart';
import 'package:lumide_gauge/src/test_run_service.dart';
import 'package:test/test.dart';

const _spec = '''
# Login

* Open the app

## Valid user
* Sign in as "ada"

## Locked user
* Sign in as "bob"
''';

void main() {
  late _Context context;
  late List<_Process> launched;
  late bool gaugeInstalled;
  late GaugeTestRunService service;

  setUp(() {
    context = _Context({
      '/project/manifest.json': '{"Language": "python"}',
      '/project/specs/login.spec': _spec,
    });
    launched = [];
    gaugeInstalled = true;
    service = GaugeTestRunService(
      context,
      flushInterval: const Duration(milliseconds: 5),
      ensureGauge: () async => gaugeInstalled,
      launch: (arguments, workingDirectory) async {
        final process = _Process(arguments, workingDirectory);
        launched.add(process);
        return process;
      },
    );
  });

  tearDown(() => service.dispose());

  _Process onlyProcess() => launched.single;

  test('runs the scenario at the cursor by its heading line', () async {
    context.editor
      ..activeUri = 'file:///project/specs/login.spec'
      ..cursorLine = 9;
    await service.runScenario();

    final process = onlyProcess();
    expect(process.workingDirectory, '/project');
    expect(process.arguments, [
      'run',
      '--machine-readable',
      'specs/login.spec:8',
    ]);
    final run = context.tests.runs.single;
    expect(run.title, 'Locked user');
    expect(run.runCommand, cmdRerun);
    expect(run.stopCommand, cmdStop);
  });

  test('asks for the cursor to be in a scenario', () async {
    context.editor
      ..activeUri = 'file:///project/specs/login.spec'
      ..cursorLine = 1;
    await service.runScenario();
    expect(launched, isEmpty);
    expect(context.window.messages.single, contains('in a scenario'));
  });

  test('runs what a Gauge code lens names', () async {
    await service.runCodeLens({
      'arguments': ['/project/specs/login.spec:5'],
    });
    expect(onlyProcess().arguments.last, 'specs/login.spec:5');
    expect(context.tests.runs.single.title, 'Valid user');
  });

  test('sends results and ends the run with a summary', () async {
    await service.runSpec({'path': '/project/specs/login.spec'});
    final process = onlyProcess();
    expect(process.arguments.last, 'specs/login.spec');
    process.emit([
      {'type': 'out', 'message': 'Python: 3.14.4'},
      {
        'type': 'specStart',
        'id': '/project/specs/login.spec',
        'name': 'Login',
        'filename': '/project/specs/login.spec',
        'line': 1,
      },
      {
        'type': 'scenarioStart',
        'id': '/project/specs/login.spec:5',
        'parentId': '/project/specs/login.spec',
        'name': 'Valid user',
        'filename': '/project/specs/login.spec',
        'line': 5,
        'result': {'time': 0},
      },
      {
        'type': 'scenarioEnd',
        'id': '/project/specs/login.spec:5',
        'parentId': '/project/specs/login.spec',
        'name': 'Valid user',
        'filename': '/project/specs/login.spec',
        'line': 5,
        'result': {'status': 'pass', 'time': 4},
      },
    ]);
    await process.exit(0);
    final run = context.tests.runs.single;
    await run.ended.future;

    expect(run.summary, '1 passed');
    expect(run.results['/project/specs/login.spec:5']?.state,
        LumideTestState.passed);
    expect(run.results['/project/specs/login.spec:5/3']?.label, 'Open the app');
    expect(run.results['/project/specs/login.spec:5/6']?.state,
        LumideTestState.passed);
    expect(run.results['/project/specs/login.spec']?.state,
        LumideTestState.skipped);
    final output = context.window.channels.single;
    expect(output.name, 'Gauge Specs: login.spec');
    expect(output.text, contains(r'$ gauge run --machine-readable'));
    expect(output.text, contains('Python: 3.14.4'));
  });

  test('reruns a scenario from the Tests pane', () async {
    await service.runAll();
    final first = onlyProcess();
    first.emit([
      {
        'type': 'scenarioStart',
        'id': '/project/specs/login.spec:8',
        'parentId': '/project/specs/login.spec',
        'name': 'Locked user',
        'filename': '/project/specs/login.spec',
        'line': 8,
      },
    ]);
    await first.exit(1);
    final run = context.tests.runs.single;
    await run.ended.future;

    await service.rerun({
      'runId': 'lumide_gauge:${run.id}',
      'testIds': ['/project/specs/login.spec:8/9'],
    });
    expect(launched.last.arguments.last, 'specs/login.spec:8');
    expect(context.tests.runs.last.title, 'Locked user');
  });

  test('stops a run and marks what was running', () async {
    await service.runAll();
    final process = onlyProcess();
    process.emit([
      {
        'type': 'specStart',
        'id': '/project/specs/login.spec',
        'name': 'Login',
        'filename': '/project/specs/login.spec',
        'line': 1,
      },
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await service.stop();

    expect(process.stopped, isTrue);
    final run = context.tests.runs.single;
    expect(run.summary, 'Stopped. No scenarios ran');
    expect(run.results['/project/specs/login.spec']?.state,
        LumideTestState.skipped);
  });

  test('says why gauge ended without running scenarios', () async {
    await service.runFailed();
    final process = onlyProcess();
    expect(process.arguments, ['run', '--machine-readable', '--failed']);
    process.emit([
      {'type': 'out', 'message': 'No failed tests found.'},
    ]);
    await process.exit(1);
    final run = context.tests.runs.single;
    await run.ended.future;
    expect(run.summary, 'gauge exited with code 1: No failed tests found.');
    expect(context.window.channels.single.shown, isTrue);
  });

  test('points at the output when gauge says nothing', () async {
    await service.runAll();
    await onlyProcess().exit(1);
    final run = context.tests.runs.single;
    await run.ended.future;
    expect(
      run.summary,
      'gauge exited with code 1. See the output for details.',
    );
  });

  test('runs specs with the tags the user enters', () async {
    context.window.input = 'smoke & !slow';
    await service.runTags();
    expect(onlyProcess().arguments.skip(2), ['--tags', 'smoke & !slow']);
  });

  test('does not run without Gauge', () async {
    gaugeInstalled = false;
    await service.runAll();
    expect(launched, isEmpty);
    expect(context.tests.runs, isEmpty);
  });

  test('warns when there is no Gauge project', () async {
    context.files.remove('/project/manifest.json');
    await service.runAll();
    expect(launched, isEmpty);
    expect(context.window.messages.single, contains('No Gauge project'));
  });
}

class _Process implements GaugeProcess {
  _Process(this.arguments, this.workingDirectory);

  final List<String> arguments;
  final String workingDirectory;
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();
  final _exit = Completer<int>();
  bool stopped = false;

  void emit(List<Map<String, Object?>> events) {
    _stdout.add('${events.map(jsonEncode).join('\n')}\n');
  }

  Future<void> exit(int code) async {
    await _stdout.close();
    await _stderr.close();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  int get pid => 1;

  @override
  Stream<String> get stdout => _stdout.stream;

  @override
  Stream<String> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> stop({bool force = false}) async {
    stopped = true;
    await exit(-15);
  }
}

class _Run implements LumideTestRun {
  _Run(this.id, this.title, this.runCommand, this.stopCommand);

  @override
  final String id;
  final String title;
  final String? runCommand;
  final String? stopCommand;
  final Map<String, LumideTestResult> results = {};
  final ended = Completer<void>();
  String? summary;

  @override
  Future<void> update(List<LumideTestResult> updates) async {
    for (final result in updates) {
      results[result.id] = result;
    }
  }

  @override
  Future<void> setCoverage(List<LumideFileCoverage> files) async {}

  @override
  Future<void> end({String? summary}) async {
    this.summary = summary;
    if (!ended.isCompleted) ended.complete();
  }
}

class _Tests implements LumideTests {
  final runs = <_Run>[];

  @override
  Future<LumideTestRun> createRun({
    required String title,
    LumideOutputChannel? output,
    String? runCommand,
    String? debugCommand,
    String? stopCommand,
    String? requestId,
  }) async {
    final run = _Run('run-${runs.length + 1}', title, runCommand, stopCommand);
    runs.add(run);
    return run;
  }
}

class _Channel implements LumideOutputChannel {
  _Channel(this.name);

  final String name;
  final lines = <String>[];
  bool shown = false;

  String get text => lines.join('\n');

  @override
  String get id => name;

  @override
  Future<void> appendLine(String value) async => lines.add(value);

  @override
  Future<void> clear() async => lines.clear();

  @override
  Future<void> show({bool preserveFocus = false}) async => shown = true;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Window implements LumideWindow {
  final channels = <_Channel>[];
  final messages = <String>[];
  String? input;

  @override
  Future<LumideOutputChannel> createOutputChannel(
    String name, {
    int? maxEntries,
  }) async {
    final channel = _Channel(name);
    channels.add(channel);
    return channel;
  }

  @override
  Future<void> showMessage(
    String message, {
    String? title,
    MessageType type = MessageType.info,
  }) async =>
      messages.add(message);

  @override
  Future<String?> showInputBox({
    String? prompt,
    String? value,
    String? placeHolder,
    bool password = false,
    String? title,
  }) async =>
      input;

  @override
  Future<bool> showConfirmDialog(String message, {String? title}) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fs implements LumideFileSystem {
  _Fs(this.files);

  final Map<String, String> files;

  @override
  Future<String> readString(String path) async =>
      files[path] ?? (throw StateError('No file $path'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Editor implements LumideEditor {
  String? activeUri;
  int cursorLine = 0;

  @override
  Future<String?> getActiveDocumentUri() async => activeUri;

  @override
  Future<String?> getDocumentText(String uri) async => null;

  @override
  Future<List<Map<String, dynamic>>> getSelections() async => [
        {
          'anchor': {'line': cursorLine, 'column': 0},
          'focus': {'line': cursorLine, 'column': 0},
        },
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Workspace implements LumideWorkspace {
  @override
  Future<List<LumideWorkspaceFolder>> getWorkspaceFolders() async =>
      [LumideWorkspaceFolder.fromUri('file:///project')];

  @override
  Future<List<String>> findFiles(
    String glob, {
    int? maxResults,
    String? folder,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Context implements LumideContext {
  _Context(this.files) : fs = _Fs(files);

  final Map<String, String> files;

  @override
  final _Tests tests = _Tests();

  @override
  final _Window window = _Window();

  @override
  final _Fs fs;

  @override
  final _Editor editor = _Editor();

  @override
  final _Workspace workspace = _Workspace();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
