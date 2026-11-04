import 'package:lumide_gauge/src/gauge_cli.dart';
import 'package:test/test.dart';

void main() {
  group('GaugeVersion.parse', () {
    test('reads the version and plugins after log lines', () {
      final version = GaugeVersion.parse('''
2026/11/04 10:51:10 Failed to get configuration from Gauge properties file.
{
    "version": "1.6.42",
    "commitHash": "8056585",
    "plugins": [
        {"name": "html-report", "version": "4.4.8"},
        {"name": "python", "version": "0.5.3"}
    ]
}
''');
      expect(version?.version, '1.6.42');
      expect(version?.plugins, {'html-report': '4.4.8', 'python': '0.5.3'});
      expect(version?.languageRunners, ['python']);
    });

    test('rejects output without a version', () {
      expect(GaugeVersion.parse('command not found'), isNull);
      expect(GaugeVersion.parse('{"plugins": []}'), isNull);
    });
  });

  test('parseGaugeTemplates reads template names', () {
    expect(
      parseGaugeTemplates('''
[
	{"key": "dotnet", "value": "https://example.com/dotnet.zip"},
	{"key": "java_maven", "value": "https://example.com/java_maven.zip"}
]
'''),
      ['dotnet', 'java_maven'],
    );
    expect(parseGaugeTemplates('nothing'), isEmpty);
  });

  test('runnerForTemplate names the runner a template needs', () {
    expect(runnerForTemplate('java_maven_selenium'), 'java');
    expect(runnerForTemplate('python'), 'python');
    expect(runnerForTemplate('ts'), 'ts');
  });

  group('gaugeManifestLanguage', () {
    test('reads the Language of a Gauge manifest', () {
      expect(
        gaugeManifestLanguage('{"Language": "python", "Plugins": []}'),
        'python',
      );
    });

    test('ignores other manifest.json files', () {
      expect(gaugeManifestLanguage('{"manifest_version": 3}'), isNull);
      expect(gaugeManifestLanguage('{"Language": ""}'), isNull);
      expect(gaugeManifestLanguage('not json'), isNull);
    });
  });
}
