# lumide_gauge

[![pub package](https://img.shields.io/pub/v/lumide_gauge.svg)](https://pub.dev/packages/lumide_gauge) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Powered by SoFluffy](https://img.shields.io/badge/Powered%20by-SoFluffy-orange)](https://sofluffy.io)

The official [Gauge](https://gauge.org) extension for [Lumide IDE](https://lumide.dev).

Write specs and concepts with Gauge's language server, and run specs, scenarios, and failed scenarios in Lumide's Tests pane.

## Features

### Specs and concepts
- **Completion**: steps and concepts as you type `*`.
- **Go to definition**: from a step to its implementation.
- **Diagnostics**: unimplemented steps and parse errors.
- **Formatting**: Format Document formats specs and concepts the Gauge way.
- **Code lenses**: Run Spec and Run Scenario above each heading.

### Running specs
- **Tests pane**: specs, scenarios, table rows, and steps, each with pass, fail, or skip, its failure message, and its line.
- **Concepts**: a concept's steps show under the step that uses it, in the concept file.
- **Run what you need**: all specs, the open spec, the scenario at the cursor, failed scenarios, or specs matching tags.
- **Rerun and stop** from the Tests pane.
- **Output**: Gauge's own output streams to a "Gauge Specs" output channel per run.

**Gauge reports results per scenario, not per step.** So step results are worked out from the scenario's errors: steps before a failing step passed, and steps after it did not run. Teardown steps (after `___`) always run, as in Gauge.

## Commands

Access these via the Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`):

| Command ID | Title | Description |
|---|---|---|
| `gauge.runAll` | **Gauge: Run All Specs** | Run every spec in the project (`gauge run`) |
| `gauge.runSpec` | **Gauge: Run Spec** | Run the open spec, or a spec or folder from the file tree |
| `gauge.runScenario` | **Gauge: Run Scenario** | Run the scenario at the cursor (`gauge run specs/a.spec:12`) |
| `gauge.runFailed` | **Gauge: Run Failed Scenarios** | Run the scenarios that failed last time (`gauge run --failed`) |
| `gauge.runTags` | **Gauge: Run Specs with Tags** | Run the specs and scenarios matching a tag expression (`--tags`) |
| `gauge.stop` | **Gauge: Stop Specs** | Stop running specs |
| `gauge.newProject` | **Gauge: New Project** | Create a project from a Gauge template (`gauge init`) |
| `gauge.installRunner` | **Gauge: Install Language Runner** | Install a runner such as `python` or `js` (`gauge install`) |
| `gauge.restartLanguageServer` | **Gauge: Restart Language Server** | Restart `gauge daemon --lsp` |

## Settings

| Key | Description |
|---|---|
| `gauge.path` | Path to the `gauge` executable. If empty, the system `PATH` is used. |

## Requirements

- **Lumide 0.25.0** or later.
- **Gauge**: install it from [docs.gauge.org](https://docs.gauge.org/getting_started/installing-gauge). Without it, the plugin says how to install it.
- **A language runner** for your step implementations, such as `gauge install python`. When a project needs a runner that is missing, the plugin offers to install it.

The plugin starts for a workspace with a Gauge `manifest.json` (one with a `Language` key), at its root or a few folders down. In a folder of several Gauge projects, each gets its own language server.

Lumide highlights `.spec` and `.cpt` files, and `.md` specs in the project's spec folders, as Gauge only inside a Gauge project, so RPM and PyInstaller `.spec` files and other Markdown keep their own handling and never reach Gauge's language server.

## How runs work

Runs use `gauge run --machine-readable`, which streams one JSON event per spec and scenario as they finish. It is built into Gauge, so it needs no report plugin, and it works with `--failed`, `--tags`, and scenario lines.

One run per project runs at a time, since Gauge keeps the last run's state for `--failed`. Stopping a run also stops the language runner Gauge started.

## Known limitations

- **Debug Scenario** code lenses, which Gauge shows for some runners, do nothing.
- **All Tests pane**: specs appear there once they have run; Lumide does not list them before.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

Built with ❤️ by [SoFluffy](https://sofluffy.io).

## Happy Testing 🦊
