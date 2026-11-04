import 'package:lumide_gauge/src/run_selection.dart';
import 'package:test/test.dart';

void main() {
  const root = '/project';

  group('GaugeInvocation', () {
    test('runs all specs with machine-readable output', () {
      const invocation = GaugeInvocation();
      expect(invocation.arguments(root), ['run', '--machine-readable']);
      expect(invocation.title(root), 'All specs');
    });

    test('runs a spec and a scenario by line, relative to the project', () {
      const invocation = GaugeInvocation(
        targets: [
          GaugeTarget('/project/specs/a.spec'),
          GaugeTarget('/project/specs/b.spec', line: 12),
        ],
      );
      expect(invocation.arguments(root), [
        'run',
        '--machine-readable',
        'specs/a.spec',
        'specs/b.spec:12',
      ]);
      expect(invocation.title(root), '2 specs and scenarios');
    });

    test('runs failed scenarios without other arguments', () {
      const invocation = GaugeInvocation(
        failedOnly: true,
        tags: 'smoke',
        targets: [GaugeTarget('/project/specs/a.spec')],
      );
      expect(
        invocation.arguments(root),
        ['run', '--machine-readable', '--failed'],
      );
      expect(invocation.title(root), 'Failed scenarios');
    });

    test('filters by tags', () {
      const invocation = GaugeInvocation(tags: ' login & !slow ');
      expect(invocation.arguments(root), [
        'run',
        '--machine-readable',
        '--tags',
        'login & !slow',
      ]);
      expect(invocation.title(root), 'tags: login & !slow');
    });

    test('titles one scenario by file and line', () {
      const invocation = GaugeInvocation(
        targets: [GaugeTarget('/project/specs/a.spec', line: 3)],
      );
      expect(invocation.title(root), 'a.spec:3');
    });
  });

  group('GaugeTarget.parse', () {
    test('reads a code lens argument with a line', () {
      expect(
        GaugeTarget.parse('/project/specs/a.spec:5'),
        const GaugeTarget('/project/specs/a.spec', line: 5),
      );
    });

    test('reads a spec without a line', () {
      expect(
        GaugeTarget.parse('/project/specs/a.spec'),
        const GaugeTarget('/project/specs/a.spec'),
      );
    });

    test('resolves a relative path against the project', () {
      expect(
        GaugeTarget.parse('specs/a.spec:7', root: root),
        const GaugeTarget('/project/specs/a.spec', line: 7),
      );
    });

    test('reads file URIs', () {
      expect(
        GaugeTarget.parse('file:///project/specs/a.spec'),
        const GaugeTarget('/project/specs/a.spec'),
      );
    });

    test('rejects an empty value', () {
      expect(GaugeTarget.parse('  '), isNull);
    });
  });

  test('invocationFor drops scenarios of specs that run whole', () {
    final invocation = invocationFor(const [
      GaugeTarget('/project/specs/a.spec', line: 3),
      GaugeTarget('/project/specs/a.spec'),
      GaugeTarget('/project/specs/b.spec', line: 9),
      GaugeTarget('/project/specs/b.spec', line: 9),
    ]);
    expect(invocation.targets, const [
      GaugeTarget('/project/specs/a.spec'),
      GaugeTarget('/project/specs/b.spec', line: 9),
    ]);
  });
}
