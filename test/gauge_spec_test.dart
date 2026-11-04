import 'dart:io';

import 'package:lumide_gauge/src/gauge_spec.dart';
import 'package:test/test.dart';

void main() {
  group('parseSpec', () {
    final spec = parseSpec(
      '/project/specs/example.spec',
      File('test/fixtures/sample/specs/example.spec').readAsStringSync(),
    );

    test('reads the heading, context steps, and scenarios', () {
      expect(spec.name, 'Specification Heading');
      expect(spec.line, 1);
      expect([for (final step in spec.contextSteps) step.line], [11]);
      expect(
          spec.contextSteps.single.text,
          'Vowels in English language are '
          '"aeiou".');
      expect([
        for (final scenario in spec.scenarios) scenario.name
      ], [
        'Vowel counts in single word',
        'Vowel counts in multiple word',
      ]);
      expect([for (final scenario in spec.scenarios) scenario.line], [13, 20]);
    });

    test('skips tags, comments, and tables', () {
      final steps = spec.scenarios.last.steps;
      expect(steps.single.line, 26);
      expect(steps.single.text, 'Almost all words have vowels');
    });

    test('ends a scenario before the next one', () {
      expect(spec.scenarios.first.endLine, 19);
      expect(spec.scenarioAt(13)?.line, 13);
      expect(spec.scenarioAt(19)?.line, 13);
      expect(spec.scenarioAt(20)?.line, 20);
      expect(spec.scenarioAt(33)?.line, 20);
      expect(spec.scenarioAt(5), isNull);
    });

    test('reads setext headings and teardown steps', () {
      final edge = parseSpec(
        '/project/specs/edge.spec',
        File('test/fixtures/edge/specs/edge.spec').readAsStringSync(),
      );
      expect(edge.name, 'Edge spec');
      expect(edge.line, 1);
      expect(edge.contextSteps.single.line, 4);
      expect([for (final scenario in edge.scenarios) scenario.line], [6, 12]);
      expect(edge.scenarios.first.steps.map((step) => step.line), [9, 10]);
      expect(edge.scenarios.last.steps.single.line, 16);
      expect(edge.scenarios.last.endLine, 17);
      expect(edge.scenarioAt(19), isNull);
      expect(edge.teardownSteps.single.text, 'Teardown runs');
    });

    test('does not take deeper headings for scenarios', () {
      final parsed = parseSpec('/a.spec', '''
# Spec
## Scenario
### Notes
* Step
''');
      expect(parsed.scenarios.single.steps.single.text, 'Step');
    });

    test('reads Windows line endings', () {
      final parsed = parseSpec('/a.spec', '# Spec\r\n\r\n## One\r\n* Step\r\n');
      expect(parsed.scenarios.single.line, 3);
      expect(parsed.scenarios.single.steps.single.line, 4);
    });
  });

  test('parseConcepts reads each concept and its steps', () {
    final concepts = parseConcepts('/project/specs/vowels.cpt', '''
# Check gauge vowels

* The word "gauge" has "3" vowels.
* Vowels in English language are "aeiou".

Check <word> again
==================
* The word <word> has "1" vowels.
''');
    expect([
      for (final concept in concepts) concept.heading
    ], [
      'Check gauge vowels',
      'Check <word> again',
    ]);
    expect([for (final concept in concepts) concept.line], [1, 6]);
    expect(concepts.first.steps.map((step) => step.line), [3, 4]);
    expect(concepts.last.steps.single.text, 'The word <word> has "1" vowels.');
  });

  group('stepPattern', () {
    test('replaces quoted and angle parameters', () {
      expect(
        stepPattern('The word "gauge" has "3" vowels.'),
        stepPattern('The word <Word> has <Count> vowels.'),
      );
      expect(stepPattern(r'Say "a \"quoted\" word"'), 'Say {}');
    });

    test('loosely ignores a table parameter Gauge adds', () {
      expect(
        looseStepPattern('Almost all words have vowels <table>'),
        looseStepPattern('Almost all words have vowels'),
      );
    });
  });
}
