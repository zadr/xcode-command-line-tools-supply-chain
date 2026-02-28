# Design: Multi-Package-Manager Support with Interactive Selection

**Date:** 2026-02-28
**Scope:** `install_macports_replacements.rb` + `xcode_clt_tools.json`

## Goal

Support both MacPorts and Homebrew as package managers. Auto-detect what is installed, prompt the user to choose if both are present, and offer to install one if neither is present. The script remains a one-liner (`curl | ruby`) with no re-run required.

## JSON Schema Change

Add `homebrew_formula` field to every tool entry in `xcode_clt_tools.json`. Value is a string (formula name) or `null` if no Homebrew equivalent exists.

Notable name differences from `macports_port`:

| Tool     | macports_port    | homebrew_formula |
|----------|-----------------|-----------------|
| make     | `gmake`         | `make`          |
| python3  | `python313`     | `python@3.13`   |
| clang    | `clang-21`      | `llvm`          |
| llvm     | `llvm-21`       | `llvm`          |
| lldb     | `lldb-21`       | `llvm`          |
| dsymutil | `llvm-21`       | `llvm`          |
| gcc      | `gcc14`         | `gcc`           |
| ctags    | `universal-ctags` | `universal-ctags` |
| cctools  | `cctools`       | `null`          |
| swift    | `null`          | `null`          |

All other tools have identical names in both package managers.

## Package Manager Abstraction

Two entries in a `PACKAGE_MANAGERS` frozen array. Each is a hash with:

- `id` — `:macports` or `:homebrew`
- `name` — display name
- `bin_name` — `"port"` or `"brew"`
- `default_bin_dirs` — directories to check if not on PATH
- `pkg_key` — JSON field to use: `"macports_port"` or `"homebrew_formula"`
- `needs_sudo` — `true` for MacPorts, `false` for Homebrew

All PM-specific install command construction and sudo logic is driven by this hash, not by branching on PM identity throughout the code.

## Detection & Selection Flow

```
detect_available_pms
  → []    (neither) → arrow-key menu: "Install MacPorts" / "Install Homebrew"
                    → install_package_manager(chosen, dry_run:)
                    → re-detect binary at known path → continue

  → [one] (one)     → puts "Using #{pm[:name]}"
                    → continue with that PM

  → [two] (both)    → arrow-key menu: "MacPorts" / "Homebrew"
                    → continue with chosen PM
```

`detect_available_pms` checks PATH first, then each PM's `default_bin_dirs`, for the binary executable.

## Interactive Arrow-Key Menu

- `require 'io/console'` — no gems, stdlib only
- `$stdout.tty?` check: TTY uses arrow-key UI, non-TTY falls back to numbered list
- Cursor hidden during selection (`\e[?25l`), restored in `ensure` block
- Arrow keys read as 3-byte escape sequences (`\e[A` up, `\e[B` down), Enter confirms, Ctrl+C exits

Rendered appearance:
```
Select a package manager:
  ▶ MacPorts
    Homebrew

↑/↓ to move · Enter to select · Ctrl+C to quit
```

## Package Manager Installation

**Homebrew:**
```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```
Run via `system()`. After it exits, check `/opt/homebrew/bin/brew` (Apple Silicon) and `/usr/local/bin/brew` (Intel) for the binary.

**MacPorts:**
1. Detect macOS version via `sw_vers -productVersion` and `-productName`
2. Fetch latest release JSON from `https://api.github.com/repos/macports/macports-base/releases/latest`
3. Match asset whose name contains the macOS version name (e.g. `Sequoia`)
4. Download the `.pkg` to a temp file
5. Run `sudo installer -pkg <tmp.pkg> -target /` via `system()`
6. After exit, check `/opt/local/bin/port` for the binary

Both installers are interactive (handle their own password prompts). Script waits via `system()` then resumes — user does not need to re-run.

## Dry-Run Behaviour

`--dry-run` threads through every stage:

- **PM installer:** prints `[dry-run] <command>` instead of running; proceeds as if installation succeeded using the known binary path
- **Tool install:** existing `[dry-run] port/brew install ...` behaviour preserved
- **Selection menu:** always shown (no skip) — user completes the full flow, dry-run only suppresses actual shell commands

## Main Flow After Refactor

```
main
  parse_options
  load_inventory
  verify_xcode_clt(inventory)        # CLT path check only (extracted from old verify_environment)
  pm = resolve_package_manager(options)  # detect → select/install → return pm hash with :bin
  puts "Using #{pm[:name]}"
  installable = filter_tools(inventory['tools'], options, pm)
  print_tool_table(installable, pm)  # column header: "Package" instead of "MacPorts Port"
  return if options[:list_only]
  abort 'Nothing to install.' if installable.empty?
  abort 'Aborted.' unless confirm_install(options)
  do_install(installable, options, pm)
```

## Changed Methods Summary

| Method | Change |
|--------|--------|
| `verify_environment` | Split into `verify_xcode_clt` (CLT path) + `resolve_package_manager` (PM detection/selection) |
| `needs_sudo?` | Now takes `pm` arg; always `false` for Homebrew |
| `run_port_install` | Renamed `run_install`; builds `port`/`brew` command from pm hash |
| `port_installed_set` | Renamed `installed_pkg_set`; uses pm-specific command |
| `port_versions` | Renamed `pkg_versions`; uses pm-specific info command |
| `filter_tools` | Takes `pm` arg; selects on `pm[:pkg_key]` |
| `print_tool_table` | Takes `pm` arg; column header updated |
| `do_install` | Takes `pm` arg; passes to `run_install` |
| (new) `PACKAGE_MANAGERS` | Frozen array of PM descriptor hashes |
| (new) `detect_available_pms` | Returns array of available PM hashes with resolved `:bin` |
| (new) `resolve_package_manager` | Orchestrates detect → select → (install) → return |
| (new) `select_with_arrows` | TTY arrow-key menu with numbered fallback |
| (new) `install_package_manager` | Dispatches Homebrew or MacPorts installer |
| (new) `install_homebrew` | Runs Homebrew install.sh via system() |
| (new) `install_macports` | Fetches .pkg, runs sudo installer via system() |
