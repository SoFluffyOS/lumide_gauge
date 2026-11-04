import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_gauge/src/commands.dart';
import 'package:test/test.dart';

void main() {
  final manifest = LumideManifest.fromYaml(
    File('plugin.yaml').readAsStringSync(),
  );

  test('plugin.yaml lists every public command with its runtime title', () {
    final manifestTitles = {
      for (final command in manifest.commands) command.id: command.title,
    };
    final publicTitles = {
      for (final entry in gaugeCommandTitles.entries)
        if (!internalGaugeCommands.contains(entry.key)) entry.key: entry.value,
    };
    expect(manifestTitles, publicTitles);
  });

  test('commands are in the Gauge category', () {
    for (final command in manifest.commands) {
      expect(command.category, 'Gauge');
    }
  });

  test('onCommand activation events name listed commands', () {
    for (final event in manifest.activationEvents) {
      if (!event.startsWith('onCommand:')) continue;
      expect(
        gaugeCommandTitles,
        contains(event.substring('onCommand:'.length)),
      );
    }
  });
}
