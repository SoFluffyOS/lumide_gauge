/// Reads the parts of Gauge specs (`.spec`) and concepts (`.cpt`) the
/// plugin needs: headings, steps, and the lines they are on.
///
/// Lines are 1-based, like Gauge's own.
library;

/// A step line, `* Step text`, with the text after the `*`.
class GaugeStep {
  const GaugeStep({required this.line, required this.text});

  final int line;
  final String text;

  @override
  String toString() => 'GaugeStep($line, $text)';
}

/// A scenario: its heading, the lines it spans, and its steps.
class GaugeScenario {
  GaugeScenario({
    required this.name,
    required this.line,
    required this.endLine,
    required this.steps,
  });

  final String name;

  /// The heading's line, which Gauge runs the scenario by
  /// (`gauge run specs/a.spec:<line>`).
  final int line;

  /// The last line of the scenario: before the next scenario or teardown,
  /// or the end of the file.
  int endLine;
  final List<GaugeStep> steps;

  bool contains(int line) => line >= this.line && line <= endLine;
}

/// A specification file.
class GaugeSpec {
  GaugeSpec({
    required this.path,
    required this.name,
    required this.line,
    required this.contextSteps,
    required this.scenarios,
    required this.teardownSteps,
  });

  final String path;
  final String name;

  /// The spec heading's line, or 1 when there is none.
  final int line;

  /// Steps before the first scenario, which run before each scenario.
  final List<GaugeStep> contextSteps;
  final List<GaugeScenario> scenarios;

  /// Steps after `___`, which run after each scenario.
  final List<GaugeStep> teardownSteps;

  /// The scenario holding [line], if any.
  GaugeScenario? scenarioAt(int line) {
    for (final scenario in scenarios) {
      if (scenario.contains(line)) return scenario;
    }
    return null;
  }

  /// The scenario whose heading is on [line].
  GaugeScenario? scenarioOnLine(int line) {
    for (final scenario in scenarios) {
      if (scenario.line == line) return scenario;
    }
    return null;
  }
}

/// A concept: a heading that names a group of steps.
class GaugeConcept {
  const GaugeConcept({
    required this.path,
    required this.heading,
    required this.line,
    required this.steps,
  });

  final String path;
  final String heading;
  final int line;
  final List<GaugeStep> steps;
}

final _hashHeading = RegExp(r'^\s*(#{1,2})(?!#)\s*(.*?)\s*#*\s*$');
final _setextSpecUnderline = RegExp(r'^\s*=+\s*$');
final _setextScenarioUnderline = RegExp(r'^\s*-+\s*$');
final _stepLine = RegExp(r'^\s*\*\s*(.*?)\s*$');
final _teardown = RegExp(r'^\s*_{3,}\s*$');

/// A heading on line [index] of [lines]: its level (1 or 2) and text.
({int level, String text})? _headingAt(List<String> lines, int index) {
  final line = lines[index];
  if (_hashHeading.firstMatch(line) case final match?) {
    return (level: match.group(1)!.length, text: match.group(2)!);
  }
  if (line.trim().isEmpty || index + 1 >= lines.length) return null;
  if (_stepLine.hasMatch(line) || line.trimLeft().startsWith('|')) return null;
  final next = lines[index + 1];
  if (_setextSpecUnderline.hasMatch(next)) {
    return (level: 1, text: line.trim());
  }
  if (_setextScenarioUnderline.hasMatch(next)) {
    return (level: 2, text: line.trim());
  }
  return null;
}

/// Parses a `.spec` file's [content].
GaugeSpec parseSpec(String path, String content) {
  final lines = content.split(RegExp(r'\r?\n'));
  String? name;
  var specLine = 1;
  final contextSteps = <GaugeStep>[];
  final scenarios = <GaugeScenario>[];
  final teardownSteps = <GaugeStep>[];
  var inTeardown = false;

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final line = lines[index];
    if (_teardown.hasMatch(line)) {
      inTeardown = true;
      if (scenarios.isNotEmpty) scenarios.last.endLine = lineNumber - 1;
      continue;
    }
    final heading = _headingAt(lines, index);
    if (heading != null) {
      if (heading.level == 1 && name == null && scenarios.isEmpty) {
        name = heading.text;
        specLine = lineNumber;
        continue;
      }
      if (heading.level == 2 && !inTeardown) {
        if (scenarios.isNotEmpty && scenarios.last.endLine >= lineNumber) {
          scenarios.last.endLine = lineNumber - 1;
        }
        scenarios.add(
          GaugeScenario(
            name: heading.text,
            line: lineNumber,
            endLine: lines.length,
            steps: [],
          ),
        );
        continue;
      }
    }
    final step = _stepLine.firstMatch(line);
    if (step == null) continue;
    final parsed = GaugeStep(line: lineNumber, text: step.group(1)!);
    if (inTeardown) {
      teardownSteps.add(parsed);
    } else if (scenarios.isEmpty) {
      contextSteps.add(parsed);
    } else {
      scenarios.last.steps.add(parsed);
    }
  }
  return GaugeSpec(
    path: path,
    name: name ?? '',
    line: specLine,
    contextSteps: contextSteps,
    scenarios: scenarios,
    teardownSteps: teardownSteps,
  );
}

/// Parses the concepts in a `.cpt` file's [content].
List<GaugeConcept> parseConcepts(String path, String content) {
  final lines = content.split(RegExp(r'\r?\n'));
  final concepts = <GaugeConcept>[];
  String? heading;
  var headingLine = 0;
  var steps = <GaugeStep>[];

  void close() {
    if (heading case final value?) {
      concepts.add(
        GaugeConcept(
          path: path,
          heading: value,
          line: headingLine,
          steps: steps,
        ),
      );
    }
  }

  for (var index = 0; index < lines.length; index++) {
    final parsedHeading = _headingAt(lines, index);
    if (parsedHeading != null && parsedHeading.level == 1) {
      close();
      heading = parsedHeading.text;
      headingLine = index + 1;
      steps = [];
      continue;
    }
    if (heading == null) continue;
    if (_stepLine.firstMatch(lines[index]) case final match?) {
      steps.add(GaugeStep(line: index + 1, text: match.group(1)!));
    }
  }
  close();
  return concepts;
}

final _quotedParameter = RegExp(r'"(?:[^"\\]|\\.)*"');
final _angleParameter = RegExp(r'<[^<>]*>');
final _whitespace = RegExp(r'\s+');

/// [text] with its parameters (`"value"`, `<name>`) replaced by `{}`, so
/// a step written with values matches the same step with placeholders.
String stepPattern(String text) => text
    .replaceAll(_quotedParameter, '{}')
    .replaceAll(_angleParameter, '{}')
    .replaceAll(_whitespace, ' ')
    .trim();

/// [stepPattern] without its parameters, for steps whose table or file
/// parameter Gauge adds to the text (`Step <table>`).
String looseStepPattern(String text) =>
    stepPattern(text).replaceAll('{}', ' ').replaceAll(_whitespace, ' ').trim();
