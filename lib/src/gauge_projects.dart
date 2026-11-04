import 'package:lumide_gauge/src/gauge_cli.dart';
import 'package:path/path.dart' as path;

/// Reads a file, or returns null when it cannot.
typedef ReadFile = Future<String?> Function(String path);

/// Whether [directory] holds a Gauge `manifest.json`.
Future<bool> isGaugeProject(String directory, ReadFile readFile) async {
  final content = await readFile(path.join(directory, 'manifest.json'));
  return content != null && gaugeManifestLanguage(content) != null;
}

/// The Gauge project holding [filePath] (a file or folder): the nearest
/// folder with a Gauge `manifest.json`, not above [boundary] when given.
Future<String?> findGaugeRoot(
  String filePath,
  ReadFile readFile, {
  String? boundary,
}) async {
  var directory = switch (path.extension(filePath).isEmpty) {
    true => path.normalize(filePath),
    false => path.dirname(path.normalize(filePath)),
  };
  while (true) {
    if (await isGaugeProject(directory, readFile)) return directory;
    if (boundary != null && path.equals(directory, boundary)) return null;
    final parent = path.dirname(directory);
    if (parent == directory) return null;
    directory = parent;
  }
}
