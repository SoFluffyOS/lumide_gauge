# Changelog

## 1.0.0

> Requires Lumide 0.25.0 or later.

- Initial release of Gauge support for Lumide IDE.
- Gauge's language server for `.spec` and `.cpt` files, and `.md` specs in a project's spec folders: completion, go to definition, diagnostics, formatting, and Run Spec and Run Scenario code lenses; one server per Gauge project, also in a folder of several.
- Starts only for a Gauge project, not for any `.spec` file, so RPM and PyInstaller specs stay out of Gauge.
- Run all specs, a spec, the scenario at the cursor, failed scenarios, or specs matching tags in the Tests pane, with results per spec, scenario, table row, and step.
- Rerun and stop runs from the Tests pane, with Gauge's output in an output channel per run.
- Create a project from a Gauge template, install language runners, and restart the language server.
- Say how to install Gauge when it is missing.
