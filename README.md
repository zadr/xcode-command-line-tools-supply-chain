# xcode-cli-supply-chain

```
curl -fsSL https://raw.githubusercontent.com/zadr/xcode-command-line-tools-supply-chain/refs/heads/main/install_macports_replacements.rb | ruby
```

Or clone and run locally:

```
ruby install_macports_replacements.rb --list
ruby install_macports_replacements.rb --dry-run
ruby install_macports_replacements.rb
```

### Why

Xcode Command Line Tools ship CLI tools at versions Apple chooses, with no way to pin or upgrade them independently. Some are very old (GNU Make 3.81, Bison 2.3, Python 3.9), Apple's `gcc` is actually clang in disguise, and Apple clang version numbers don't correspond to upstream LLVM releases. This project replaces them with MacPorts equivalents so you control what versions you run.

### How it works

`xcode_clt_tools.json` is an inventory of every tool in the CLT bin directory, mapped to its MacPorts replacement where one exists. The Ruby script reads that file, checks what's already installed, and runs `port install` for the rest. It detects non-root MacPorts installs (via `--with-no-root-privileges`) automatically and skips `sudo` when it isn't needed.

### Usage

Use `--tools` or `--skip` to target specific tools, or `--dry-run` to preview without installing anything. The JSON file is the source of truth — edit it to change port versions, add tools, or swap replacements.
