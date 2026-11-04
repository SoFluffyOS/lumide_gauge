import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_gauge/src/constants.dart';
import 'package:lumide_gauge/src/gauge_cli.dart';
import 'package:lumide_gauge/src/gauge_projects.dart';
import 'package:path/path.dart' as path;

/// Finds Gauge and Gauge projects, runs the language server, and creates
/// projects and installs language runners.
class GaugeService {
  GaugeService(this.context, {this.log});

  final LumideContext context;
  final void Function(String message)? log;

  /// The `gauge` executable, from the `gauge.path` setting or PATH.
  String command = 'gauge';

  /// The installed Gauge, or null when it was not found.
  GaugeVersion? version;

  /// Gauge projects found in the workspace.
  List<String> projects = const [];

  LumideOutputChannel? _channel;

  /// Reads the `gauge.path` setting.
  Future<void> loadSettings() async {
    try {
      final custom = await context.workspace.getConfiguration(settingGaugePath);
      command = switch (custom) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => 'gauge',
      };
    } catch (error) {
      log?.call('Could not read $settingGaugePath: $error');
    }
  }

  /// Asks Gauge for its version and plugins.
  Future<GaugeVersion?> refreshVersion() async {
    try {
      final result = await context.shell.run(
        command,
        const ['version', '--machine-readable'],
      );
      version = switch (result.exitCode) {
        0 => GaugeVersion.parse(result.stdout),
        _ => null,
      };
      if (version == null) {
        log?.call('gauge version failed (${result.exitCode}): '
            '${result.stderr.trim()}');
      }
    } catch (error) {
      version = null;
      log?.call('Could not run gauge: $error');
    }
    return version;
  }

  /// Whether Gauge is installed. When it is not, says how to install it:
  /// with a dialog that opens the install guide when [ask], or else with a
  /// message.
  Future<bool> ensureInstalled({bool ask = true}) async {
    if (version != null || await refreshVersion() != null) return true;
    const message = 'Gauge is not installed, or "gauge" is not on PATH. '
        'Install it from $gaugeInstallUrl, or set its path in the '
        '"$settingGaugePath" setting.';
    try {
      if (!ask) {
        await context.window.showMessage(
          message,
          title: 'Gauge',
          type: MessageType.warning,
        );
        return false;
      }
      final open = await context.window.showConfirmDialog(
        '$message\n\nOpen the install guide?',
        title: 'Gauge Is Not Installed',
      );
      if (open) await context.window.openUrl(gaugeInstallUrl);
    } catch (error) {
      log?.call('Could not tell that Gauge is missing: $error');
    }
    return false;
  }

  /// Finds the Gauge projects in the workspace: workspace folders with a
  /// Gauge `manifest.json`, else folders inside them that have one.
  Future<List<String>> findProjects() async {
    final found = <String>[];
    final folders = await _workspaceFolders();
    for (final folder in folders) {
      if (await isGaugeProject(folder, _read)) found.add(folder);
    }
    if (found.isEmpty) {
      try {
        final manifests = await context.workspace.findFiles(
          '**/manifest.json',
          maxResults: 50,
        );
        for (final uri in manifests) {
          final file = _toPath(uri);
          if (file.contains('${path.separator}node_modules${path.separator}')) {
            continue;
          }
          final directory = path.dirname(file);
          if (await isGaugeProject(directory, _read)) found.add(directory);
        }
      } catch (error) {
        log?.call('Could not search for Gauge projects: $error');
      }
    }
    found.sort((a, b) => a.length.compareTo(b.length));
    return projects = found;
  }

  /// Starts Gauge's language server for `.spec` and `.cpt` files. Gauge
  /// projects that are workspace folders each get their own server;
  /// otherwise the server runs for the first project found.
  Future<void> registerLanguageServer() async {
    if (projects.isEmpty) {
      log?.call('No Gauge project; the language server is not started.');
      return;
    }
    final folders = (await _workspaceFolders()).toSet();
    final perFolder = projects.every(folders.contains);
    if (!perFolder && projects.length > 1) {
      log?.call('Several Gauge projects inside workspace folders; the '
          'language server runs for ${projects.first}.');
    }
    await context.languages.registerLanguageServer(
      id: languageServerId,
      languageId: gaugeLanguageId,
      displayName: 'Gauge',
      fileExtensions: gaugeFileExtensions,
      command: command,
      args: [
        'daemon',
        '--lsp',
        if (!perFolder) '--dir=${projects.first}',
      ],
      runsPerFolder: perFolder,
    );
    log?.call('Gauge language server registered for ${projects.join(', ')}');
  }

  /// Tells the user about projects whose language runner is missing.
  Future<void> checkRunners() async {
    final installed = version?.plugins ?? const {};
    final missing = <String>{};
    for (final project in projects) {
      final language = await projectLanguage(project);
      if (language != null && !installed.containsKey(language)) {
        missing.add(language);
      }
    }
    if (missing.isEmpty) return;
    final runners = missing.join(', ');
    try {
      final install = await context.window.showConfirmDialog(
        'This Gauge project needs the $runners language runner, which is '
        'not installed. Install it now?',
        title: 'Install Gauge Runner',
      );
      if (!install) return;
      for (final runner in missing) {
        await installRunner(runner: runner);
      }
    } catch (error) {
      log?.call('Could not offer to install $runners: $error');
    }
  }

  /// The `Language` of [project]'s manifest.
  Future<String?> projectLanguage(String project) async {
    final content = await _read(path.join(project, 'manifest.json'));
    return content == null ? null : gaugeManifestLanguage(content);
  }

  /// Installs a language runner, asking which one unless [runner] is set.
  Future<void> installRunner({String? runner}) async {
    if (!await ensureInstalled()) return;
    final chosen = runner ?? await _pickRunner();
    if (chosen == null) return;
    final ok = await _runWithProgress(
      title: 'Installing the Gauge $chosen runner',
      arguments: ['install', chosen],
    );
    await refreshVersion();
    await _show(
      switch (ok) {
        true => 'Installed the Gauge $chosen runner.',
        false => 'Could not install the Gauge $chosen runner. See the Gauge '
            'output for details.',
      },
      ok: ok,
    );
  }

  Future<String?> _pickRunner() async {
    final installed = version?.plugins ?? const {};
    final languages = {
      for (final project in projects)
        if (await projectLanguage(project) case final language?) language,
    };
    final runners = gaugeLanguageRunners.keys.toList()
      ..sort((a, b) {
        final aFirst = languages.contains(a) ? 0 : 1;
        final bFirst = languages.contains(b) ? 0 : 1;
        return aFirst.compareTo(bFirst);
      });
    final picked = await context.window.showQuickPick(
      [
        for (final runner in runners)
          QuickPickItem(
            label: runner,
            description: gaugeLanguageRunners[runner],
            detail: switch ((installed[runner], languages.contains(runner))) {
              (final version?, _) => 'Installed${switch (version) {
                  '' => '',
                  _ => ' ($version)',
                }}; installing updates it',
              (null, true) => 'Needed by this project',
              _ => null,
            },
            payload: runner,
          ),
      ],
      placeholder: 'Language runner to install',
    );
    return switch (picked?.payload) {
      final String runner => runner,
      _ => picked?.label,
    };
  }

  /// Creates a project from a Gauge template in a folder the user picks.
  Future<void> newProject() async {
    if (!await ensureInstalled()) return;
    final template = await _pickTemplate();
    if (template == null) return;
    final folders = await _workspaceFolders();
    final folder = await context.window.showOpenFolderDialog(
      title: 'Folder for the new Gauge project',
      defaultPath: folders.firstOrNull,
    );
    if (folder == null || folder.isEmpty) return;
    if (await isGaugeProject(folder, _read)) {
      await _show('$folder is already a Gauge project.', ok: false);
      return;
    }
    final ok = await _runWithProgress(
      title: 'Creating a Gauge $template project',
      arguments: ['init', template],
      workingDirectory: folder,
    );
    await refreshVersion();
    if (!ok) {
      await _show(
        'Could not create the project. See the Gauge output for details.',
        ok: false,
      );
      return;
    }
    await _show('Created a Gauge $template project in $folder.', ok: true);
    if (folders.any((root) => path.equals(root, folder))) {
      await findProjects();
      await registerLanguageServer();
    }
  }

  Future<String?> _pickTemplate() async {
    var templates = <String>[];
    try {
      final result = await context.shell.run(
        command,
        const ['template', '--list', '--machine-readable'],
      );
      if (result.exitCode == 0) templates = parseGaugeTemplates(result.stdout);
    } catch (error) {
      log?.call('Could not list Gauge templates: $error');
    }
    if (templates.isEmpty) templates = List.of(defaultGaugeTemplates);
    final installed = version?.plugins ?? const {};
    bool hasRunner(String template) =>
        installed.containsKey(runnerForTemplate(template));
    templates.sort((a, b) {
      final byRunner = (hasRunner(a) ? 0 : 1).compareTo(hasRunner(b) ? 0 : 1);
      return byRunner != 0 ? byRunner : a.compareTo(b);
    });
    final picked = await context.window.showQuickPick(
      [
        for (final template in templates)
          QuickPickItem(
            label: template,
            description: gaugeLanguageRunners[runnerForTemplate(template)],
            detail: switch (hasRunner(template)) {
              true => 'Runner installed',
              false => 'Gauge installs the ${runnerForTemplate(template)} '
                  'runner',
            },
            payload: template,
          ),
      ],
      placeholder: 'Gauge project template',
    );
    return switch (picked?.payload) {
      final String template => template,
      _ => picked?.label,
    };
  }

  /// Runs `gauge` with [arguments], writing its output to the Gauge
  /// channel. Returns whether it succeeded.
  Future<bool> _runWithProgress({
    required String title,
    required List<String> arguments,
    String? workingDirectory,
  }) async {
    final channel = await _outputChannel();
    await _append(channel, '\$ gauge ${arguments.join(' ')}');
    try {
      final result = await context.window.withProgress(
        title: title,
        task: (_) => context.shell.run(
          command,
          arguments,
          workingDirectory: workingDirectory,
        ),
      );
      await _append(channel, result.stdout.trimRight());
      await _append(channel, result.stderr.trimRight());
      return result.exitCode == 0;
    } catch (error) {
      await _append(channel, 'Could not run gauge: $error');
      return false;
    }
  }

  Future<LumideOutputChannel?> _outputChannel() async {
    if (_channel case final channel?) return channel;
    try {
      return _channel = await context.window.createOutputChannel(channelGauge);
    } catch (error) {
      log?.call('Could not create the Gauge output channel: $error');
      return null;
    }
  }

  Future<void> _append(LumideOutputChannel? channel, String text) async {
    if (channel == null || text.isEmpty) return;
    try {
      await channel.appendLine(text);
    } catch (error) {
      log?.call('Could not write Gauge output: $error');
    }
  }

  Future<void> _show(String message, {required bool ok}) async {
    try {
      await context.window.showMessage(
        message,
        title: 'Gauge',
        type: ok ? MessageType.info : MessageType.error,
      );
    } catch (error) {
      log?.call('Could not show "$message": $error');
    }
  }

  Future<void> dispose() async {
    final channel = _channel;
    _channel = null;
    try {
      await channel?.dispose();
    } catch (_) {
      // Lumide already disposed it.
    }
  }

  Future<List<String>> _workspaceFolders() async {
    try {
      return [
        for (final folder in await context.workspace.getWorkspaceFolders())
          _toPath(folder.uri),
      ];
    } catch (error) {
      log?.call('Could not list workspace folders: $error');
      return const [];
    }
  }

  Future<String?> _read(String file) async {
    try {
      return await context.fs.readString(file);
    } catch (_) {
      return null;
    }
  }

  static String _toPath(String value) => switch (value.startsWith('file:')) {
        true => Uri.parse(value).toFilePath(),
        false => value,
      };
}
