# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Lint
bundle exec rubocop

# Run the script (requires macOS with Xcode CLT and MacPorts)
ruby install_macports_replacements.rb --list      # list tools and status
ruby install_macports_replacements.rb --dry-run   # preview installs
ruby install_macports_replacements.rb             # install all

# Filter options
ruby install_macports_replacements.rb --tools git,make
ruby install_macports_replacements.rb --skip python3
ruby install_macports_replacements.rb --assume-yes
```

## Architecture

This project has two components:

**`xcode_clt_tools.json`** — the source of truth. An inventory of every binary in `/Library/Developer/CommandLineTools/usr/bin`, each entry mapping the Apple-provided tool to its MacPorts port name (or `null` if no replacement exists). Edit this file to change port versions, add tools, or swap replacements.

**`install_macports_replacements.rb`** — a standalone Ruby script (no gems required at runtime, stdlib only). It reads the JSON inventory, queries `port installed` and `port info` to determine what's already installed and at what version, prints a table, then runs `port install` for missing ports. Auto-detects whether `sudo` is needed by checking if the MacPorts prefix is writable.

When run via `curl | ruby`, `INVENTORY_LOCAL` is nil so the script fetches the JSON from GitHub directly.

## RuboCop

All metrics cops (MethodLength, AbcSize, CyclomaticComplexity, PerceivedComplexity) are enabled with default thresholds. Keep methods small and extract helpers rather than disabling cops.
