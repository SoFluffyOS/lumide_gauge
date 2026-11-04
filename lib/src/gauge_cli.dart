import 'dart:convert';

/// Where to get Gauge, shown when it is not installed.
const gaugeInstallUrl =
    'https://docs.gauge.org/getting_started/installing-gauge';

/// Gauge's language runners, by plugin name.
const gaugeLanguageRunners = {
  'python': 'Python',
  'js': 'JavaScript',
  'ts': 'TypeScript',
  'java': 'Java',
  'dotnet': 'C# (.NET)',
  'ruby': 'Ruby',
};

/// Templates Gauge ships, used when `gauge template --list` fails.
const defaultGaugeTemplates = [
  'dotnet',
  'java',
  'java_gradle',
  'java_maven',
  'java_maven_selenium',
  'js',
  'js_simple',
  'python',
  'python_selenium',
  'ruby',
  'ruby_selenium',
  'ts',
];

/// The installed Gauge, from `gauge version --machine-readable`.
class GaugeVersion {
  const GaugeVersion({required this.version, required this.plugins});

  final String version;

  /// Installed plugin names and versions, runners and reports alike.
  final Map<String, String> plugins;

  Iterable<String> get languageRunners =>
      plugins.keys.where(gaugeLanguageRunners.containsKey);

  /// Parses the JSON Gauge prints. Gauge may print log lines before it,
  /// such as a missing `gauge.properties`, so the JSON is found first.
  static GaugeVersion? parse(String output) {
    final start = output.indexOf('{');
    final end = output.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? json;
    try {
      json = jsonDecode(output.substring(start, end + 1));
    } on FormatException {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    final version = json['version'];
    if (version is! String) return null;
    return GaugeVersion(
      version: version,
      plugins: {
        for (final plugin in json['plugins'] as List? ?? const [])
          if (plugin case {'name': final String name})
            name: switch (plugin) {
              {'version': final String pluginVersion} => pluginVersion,
              _ => '',
            },
      },
    );
  }
}

/// Template names from `gauge template --list --machine-readable`.
List<String> parseGaugeTemplates(String output) {
  final start = output.indexOf('[');
  final end = output.lastIndexOf(']');
  if (start < 0 || end <= start) return const [];
  try {
    final json = jsonDecode(output.substring(start, end + 1));
    if (json is! List) return const [];
    return [
      for (final entry in json)
        if (entry case {'key': final String key}) key,
    ];
  } on FormatException {
    return const [];
  }
}

/// The runner a template needs: `java_maven` needs `java`.
String runnerForTemplate(String template) => template.split('_').first;

/// The `Language` of a Gauge project's `manifest.json`, or null when
/// [content] is not a Gauge manifest (web extensions have one too).
String? gaugeManifestLanguage(String content) {
  try {
    final json = jsonDecode(content);
    if (json case {'Language': final String language}
        when language.trim().isNotEmpty) {
      return language.trim();
    }
  } on FormatException {
    return null;
  }
  return null;
}
