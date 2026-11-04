import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_gauge/lumide_gauge.dart';

void main() => GaugePlugin().run();

/// Gauge support: the language server for specs and concepts, and running
/// specs in the Tests pane.
class GaugePlugin extends LumidePlugin {
  late GaugeService gauge;
  late HostGaugeLauncher launcher;
  late GaugeTestRunService testRuns;

  @override
  Future<void> onActivate(LumideContext context) async {
    gauge = GaugeService(context, log: log);
    await gauge.loadSettings();
    launcher = HostGaugeLauncher(context.shell, command: gauge.command);
    testRuns = GaugeTestRunService(
      context,
      launch: launcher.start,
      ensureGauge: gauge.ensureInstalled,
      log: log,
    );

    await _registerCommands(context);

    final projects = await gauge.findProjects();
    if (projects.isEmpty) {
      log('No Gauge project in the workspace.');
      return;
    }
    if (await gauge.refreshVersion() == null) {
      await gauge.ensureInstalled(ask: false);
      return;
    }
    log('Gauge ${gauge.version?.version} found for ${projects.join(', ')}');
    await gauge.registerLanguageServer();
    await gauge.checkRunners();
  }

  Future<void> _registerCommands(LumideContext context) async {
    final callbacks = <String, Future<void> Function([Map<String, dynamic>?])>{
      cmdRunAll: testRuns.runAll,
      cmdRunSpec: testRuns.runSpec,
      cmdRunScenario: testRuns.runScenario,
      cmdRunFailed: testRuns.runFailed,
      cmdRunTags: testRuns.runTags,
      cmdStop: testRuns.stop,
      cmdRerun: testRuns.rerun,
      cmdExecute: testRuns.runCodeLens,
      cmdNewProject: ([_]) => gauge.newProject(),
      cmdInstallRunner: ([args]) => gauge.installRunner(
            runner: switch (args?['runner']) {
              final String runner when runner.isNotEmpty => runner,
              _ => null,
            },
          ),
      cmdRestartLanguageServer: ([_]) => _restartLanguageServer(context),
    };
    for (final MapEntry(key: id, value: callback) in callbacks.entries) {
      await context.commands.registerCommand(
        id: id,
        title: gaugeCommandTitles[id] ?? id,
        category: 'Gauge',
        callback: callback,
      );
    }
  }

  Future<void> _restartLanguageServer(LumideContext context) async {
    await gauge.loadSettings();
    launcher.command = gauge.command;
    gauge.version = null;
    if (!await gauge.ensureInstalled()) return;
    await gauge.findProjects();
    if (gauge.projects.isEmpty) {
      await context.window.showMessage(
        'No Gauge project found. A Gauge project has a manifest.json with a '
        '"Language" key.',
        title: 'Gauge',
        type: MessageType.warning,
      );
      return;
    }
    await gauge.registerLanguageServer();
    await context.window.showMessage(
      'Gauge language server restarted.',
      title: 'Gauge',
    );
  }

  @override
  Future<void> onDeactivate() async {
    await testRuns.dispose();
    launcher.dispose();
    await gauge.dispose();
  }
}
