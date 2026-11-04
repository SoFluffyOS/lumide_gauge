import 'package:lumide_gauge/src/constants.dart';

/// Commands registered at runtime but not listed in the Command Palette,
/// because they only work with arguments supplied by Lumide.
const Set<String> internalGaugeCommands = {cmdRerun, cmdExecute};

/// Titles for every command the plugin registers, keyed by command id.
///
/// `plugin.yaml` must list the same commands with the same titles, except
/// [internalGaugeCommands]; `test/commands_manifest_test.dart` enforces it.
const Map<String, String> gaugeCommandTitles = {
  cmdRunAll: 'Gauge: Run All Specs',
  cmdRunSpec: 'Gauge: Run Spec',
  cmdRunScenario: 'Gauge: Run Scenario',
  cmdRunFailed: 'Gauge: Run Failed Scenarios',
  cmdRunTags: 'Gauge: Run Specs with Tags',
  cmdStop: 'Gauge: Stop Specs',
  cmdNewProject: 'Gauge: New Project',
  cmdInstallRunner: 'Gauge: Install Language Runner',
  cmdRestartLanguageServer: 'Gauge: Restart Language Server',
  cmdRerun: 'Gauge: Rerun Specs',
  cmdExecute: 'Gauge: Run Spec or Scenario',
};
