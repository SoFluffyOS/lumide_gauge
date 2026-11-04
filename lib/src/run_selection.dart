import 'package:path/path.dart' as path;

/// A spec file, or the scenario on [line] of it, to run.
class GaugeTarget {
  const GaugeTarget(this.file, {this.line});

  /// Absolute path of the spec file, or of a folder of specs.
  final String file;

  /// 1-based line of a scenario; null runs the whole file.
  final int? line;

  /// The `gauge run` argument: the path relative to [root], with `:line`.
  String argument(String root) {
    final relative = switch (path.isWithin(root, file)) {
      true => path.relative(file, from: root),
      false => file,
    };
    final portable = relative.replaceAll(r'\', '/');
    return switch (line) {
      final value? => '$portable:$value',
      null => portable,
    };
  }

  /// Parses `specs/a.spec` or `specs/a.spec:12`, as Gauge's code lenses
  /// pass them; a relative path resolves against [root].
  static GaugeTarget? parse(String value, {String? root}) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final filePath = switch (text.startsWith('file:')) {
      true => Uri.parse(text).toFilePath(),
      false => text,
    };
    final match = RegExp(r'^(.*\.(?:spec|md|cpt)):(\d+)$').firstMatch(filePath);
    final (file, line) = switch (match) {
      final value? => (value.group(1)!, int.parse(value.group(2)!)),
      null => (filePath, null),
    };
    final absolute = switch ((path.isAbsolute(file), root)) {
      (false, final base?) => path.normalize(path.join(base, file)),
      _ => path.normalize(file),
    };
    return GaugeTarget(absolute, line: line);
  }

  @override
  bool operator ==(Object other) =>
      other is GaugeTarget && other.file == file && other.line == line;

  @override
  int get hashCode => Object.hash(file, line);

  @override
  String toString() => line == null ? file : '$file:$line';
}

/// What a `gauge run` runs: some targets (all specs when empty), only the
/// scenarios that failed last time, or those matching a tag expression.
class GaugeInvocation {
  const GaugeInvocation({
    this.targets = const [],
    this.failedOnly = false,
    this.tags,
  });

  final List<GaugeTarget> targets;

  /// `gauge run --failed`, which takes no other arguments.
  final bool failedOnly;

  /// A tag expression for `--tags`, such as `login & !slow`.
  final String? tags;

  /// The arguments after `gauge`.
  List<String> arguments(String root) => [
        'run',
        '--machine-readable',
        if (failedOnly)
          '--failed'
        else ...[
          if (tags case final value? when value.trim().isNotEmpty) ...[
            '--tags',
            value.trim(),
          ],
          for (final target in targets) target.argument(root),
        ],
      ];

  /// A short title for the run, such as `example.spec:12`.
  String title(String root) {
    if (failedOnly) return 'Failed scenarios';
    final tagsTitle = switch (tags) {
      final value? when value.trim().isNotEmpty => 'tags: ${value.trim()}',
      _ => null,
    };
    final targetsTitle = switch (targets) {
      [] => null,
      [final target] => _targetTitle(target),
      _ => '${targets.length} specs and scenarios',
    };
    return switch ((targetsTitle, tagsTitle)) {
      (null, null) => 'All specs',
      (final value?, null) => value,
      (null, final value?) => value,
      (final targetValue?, final tagsValue?) => '$targetValue ($tagsValue)',
    };
  }

  static String _targetTitle(GaugeTarget target) => switch (target.line) {
        final line? => '${path.basename(target.file)}:$line',
        null => path.basename(target.file),
      };
}

/// One invocation running [targets]: a spec target covers the scenarios
/// inside it, so they are dropped.
GaugeInvocation invocationFor(Iterable<GaugeTarget> targets) {
  final unique = targets.toSet().toList();
  final wholeFiles = {
    for (final target in unique)
      if (target.line == null) target.file,
  };
  return GaugeInvocation(
    targets: [
      for (final target in unique)
        if (target.line == null || !wholeFiles.contains(target.file)) target,
    ],
  );
}
