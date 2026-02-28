# Multi-Package-Manager Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Homebrew support alongside MacPorts — auto-detect which is installed, offer an arrow-key menu when choice is needed, and optionally install either PM if neither is present.

**Architecture:** `xcode_clt_tools.json` gains `homebrew_formula` per tool. The script gains a `PACKAGE_MANAGERS` descriptor array driving all PM-specific logic. A `resolve_package_manager` function handles detect→select→(install)→return, threading the resolved PM hash into all downstream methods. The interactive menu uses `io/console` with a TTY fallback.

**Tech Stack:** Ruby stdlib only (`io/console`, `open3`, `open-uri`, `json`). No gems. Single script. macOS only.

---

### Task 1: Add `homebrew_formula` to `xcode_clt_tools.json`

**Files:**
- Modify: `xcode_clt_tools.json`

**Step 1: Add the field to every tool entry**

Edit `xcode_clt_tools.json`. Add `"homebrew_formula"` after `"macports_port"` in each tool object. Use these values (note the names that differ from the MacPorts port):

```json
{ "name": "git",      "macports_port": "git",          "homebrew_formula": "git" }
{ "name": "make",     "macports_port": "gmake",         "homebrew_formula": "make" }
{ "name": "bison",    "macports_port": "bison",         "homebrew_formula": "bison" }
{ "name": "flex",     "macports_port": "flex",          "homebrew_formula": "flex" }
{ "name": "m4",       "macports_port": "m4",            "homebrew_formula": "m4" }
{ "name": "gperf",    "macports_port": "gperf",         "homebrew_formula": "gperf" }
{ "name": "python3",  "macports_port": "python313",     "homebrew_formula": "python@3.13" }
{ "name": "clang",    "macports_port": "clang-21",      "homebrew_formula": "llvm" }
{ "name": "llvm",     "macports_port": "llvm-21",       "homebrew_formula": "llvm" }
{ "name": "gcc",      "macports_port": "gcc14",         "homebrew_formula": "gcc" }
{ "name": "ctags",    "macports_port": "universal-ctags","homebrew_formula": "universal-ctags" }
{ "name": "libtool",  "macports_port": "libtool",       "homebrew_formula": "libtool" }
{ "name": "byacc",    "macports_port": "byacc",         "homebrew_formula": "byacc" }
{ "name": "unifdef",  "macports_port": "unifdef",       "homebrew_formula": "unifdef" }
{ "name": "binutils", "macports_port": "binutils",      "homebrew_formula": "binutils" }
{ "name": "cctools",  "macports_port": "cctools",       "homebrew_formula": null }
{ "name": "dsymutil", "macports_port": "llvm-21",       "homebrew_formula": "llvm" }
{ "name": "lldb",     "macports_port": "lldb-21",       "homebrew_formula": "llvm" }
{ "name": "swift",    "macports_port": null,            "homebrew_formula": null }
{ "name": "ld",       "macports_port": "mold",          "homebrew_formula": "mold" }
```

**Step 2: Verify JSON is valid**

```bash
ruby -e 'require "json"; j = JSON.parse(File.read("xcode_clt_tools.json")); puts j["tools"].map { |t| "#{t["name"]}: macports=#{t["macports_port"]} brew=#{t["homebrew_formula"]}" }'
```

Expected: 20 lines printed, no parse error.

**Step 3: Commit**

```bash
git add xcode_clt_tools.json
git commit -m "feat: add homebrew_formula field to tool inventory"
```

---

### Task 2: Add `PACKAGE_MANAGERS` constant and update PATH bootstrapping

**Files:**
- Modify: `install_macports_replacements.rb` (top of file, replacing existing `MACPORTS_DEFAULT_BIN` block)

**Step 1: Replace the existing `MACPORTS_DEFAULT_BIN` constant and `ENV['PATH']` line with the following**

Remove these lines:
```ruby
MACPORTS_DEFAULT_BIN = '/opt/local/bin'

# MacPorts may not be on PATH if the shell profile hasn't been sourced (e.g. curl | ruby).
# Prepend the default MacPorts bin directory so subprocesses can find `port`.
ENV['PATH'] = "#{MACPORTS_DEFAULT_BIN}:#{ENV['PATH']}" unless ENV['PATH'].split(':').include?(MACPORTS_DEFAULT_BIN)
```

Replace with:
```ruby
PACKAGE_MANAGERS = [
  { id: :macports, name: 'MacPorts', bin_name: 'port',
    default_bin_dirs: ['/opt/local/bin'],
    pkg_key: 'macports_port', needs_sudo: true,
    install_label: 'MacPorts  (macports.org)' },
  { id: :homebrew, name: 'Homebrew', bin_name: 'brew',
    default_bin_dirs: ['/opt/homebrew/bin', '/usr/local/bin'],
    pkg_key: 'homebrew_formula', needs_sudo: false,
    install_label: 'Homebrew  (brew.sh)' }
].freeze

# When invoked via curl | ruby the shell profile hasn't been sourced.
# Prepend each PM's default bin dir so `which` and Open3 calls can find them.
PACKAGE_MANAGERS.each do |pm|
  pm[:default_bin_dirs].each do |dir|
    ENV['PATH'] = "#{dir}:#{ENV['PATH']}" unless ENV['PATH'].split(':').include?(dir)
  end
end
```

**Step 2: Verify Ruby parses cleanly**

```bash
ruby -c install_macports_replacements.rb
```

Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add install_macports_replacements.rb
git commit -m "feat: add PACKAGE_MANAGERS descriptor constant"
```

---

### Task 3: Add `find_pm_binary` and `detect_available_pms`

**Files:**
- Modify: `install_macports_replacements.rb` (add after the constant block, before `load_inventory`)

**Step 1: Add these two methods**

```ruby
def find_pm_binary(pm)
  # Prefer whatever is on PATH; fall back to known install locations.
  out, status = Open3.capture2('which', pm[:bin_name])
  path = out.strip
  return path if status.success? && File.executable?(path)

  pm[:default_bin_dirs].each do |dir|
    full = File.join(dir, pm[:bin_name])
    return full if File.executable?(full)
  end
  nil
rescue Errno::ENOENT
  nil
end

def detect_available_pms
  PACKAGE_MANAGERS.filter_map do |pm|
    bin = find_pm_binary(pm)
    bin ? pm.merge(bin: bin) : nil
  end
end
```

**Step 2: Verify with a quick smoke test**

```bash
ruby -e '
  require_relative "install_macports_replacements"
  puts detect_available_pms.map { |pm| "#{pm[:name]}: #{pm[:bin]}" }
'
```

Expected: prints whichever of MacPorts / Homebrew you have installed (at least one should appear on your dev machine).

**Step 3: Commit**

```bash
git add install_macports_replacements.rb
git commit -m "feat: add PM binary detection"
```

---

### Task 4: Add interactive arrow-key menu

**Files:**
- Modify: `install_macports_replacements.rb` (add `require 'io/console'` at top; add menu methods before `load_inventory`)

**Step 1: Add `require 'io/console'` to the require block at the top of the file**

```ruby
require 'io/console'
```

**Step 2: Add these menu methods after `detect_available_pms`**

```ruby
def read_key
  char = $stdin.getch
  return char unless char == "\e"

  # Try to read the two-byte escape sequence (arrow keys = "\e[A" etc.).
  # Non-blocking so a bare Escape keypress doesn't hang.
  begin
    char += $stdin.read_nonblock(2)
  rescue IO::WaitReadable
    # lone Escape — return as-is
  end
  char
end

def render_menu_lines(prompt, labels, selected)
  lines = ["#{prompt}"]
  labels.each_with_index do |label, i|
    lines << (i == selected ? "  \e[1m\u25B6 #{label}\e[0m" : "    #{label}")
  end
  lines << ''
  lines << "\e[2m\u2191/\u2193 to move \u00B7 Enter to select \u00B7 Ctrl+C to quit\e[0m"
  lines
end

def arrow_key_menu(prompt, labels)
  selected = 0
  first = true
  line_count = 0

  $stdout.print "\e[?25l" # hide cursor
  begin
    $stdin.raw do
      loop do
        $stdout.print("\e[#{line_count}A") unless first # move up to redraw
        lines = render_menu_lines(prompt, labels, selected)
        line_count = lines.size
        puts lines
        first = false

        case read_key
        when "\e[A", "\e[D" then selected = (selected - 1) % labels.size # up/left
        when "\e[B", "\e[C" then selected = (selected + 1) % labels.size # down/right
        when "\r", "\n"     then break
        when "\u0003"       then puts; exit(1) # Ctrl+C
        end
      end
    end
  ensure
    $stdout.print "\e[?25h" # restore cursor
  end
  selected
end

def numbered_menu(prompt, labels)
  puts prompt
  labels.each_with_index { |label, i| puts "  #{i + 1}. #{label}" }
  loop do
    print "Enter number (1-#{labels.size}): "
    input = $stdin.gets&.strip
    exit(1) if input.nil?
    n = input.to_i
    return n - 1 if n.between?(1, labels.size)

    puts "Invalid choice. Please enter 1-#{labels.size}."
  end
end

def select_with_arrows(prompt, labels)
  $stdout.tty? ? arrow_key_menu(prompt, labels) : numbered_menu(prompt, labels)
end
```

**Step 3: Verify Ruby parses cleanly**

```bash
ruby -c install_macports_replacements.rb
```

Expected: `Syntax OK`

**Step 4: Commit**

```bash
git add install_macports_replacements.rb
git commit -m "feat: add interactive arrow-key menu"
```

---

### Task 5: Add PM installer methods

**Files:**
- Modify: `install_macports_replacements.rb` (add after `select_with_arrows`, before `load_inventory`)

**Step 1: Add `install_homebrew`**

```ruby
def install_homebrew(dry_run:)
  cmd = '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  if dry_run
    puts "  [dry-run] #{cmd}"
    return
  end
  system('/bin/bash', '-c',
         '$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)') # rubocop:disable Layout/LineLength
end
```

**Step 2: Add `install_macports`**

```ruby
def macos_major_version
  out, = Open3.capture2('sw_vers', '-productVersion')
  out.strip.split('.').first
rescue Errno::ENOENT
  nil
end

def macports_pkg_url
  api_url = 'https://api.github.com/repos/macports/macports-base/releases/latest'
  json = URI.parse(api_url).open('User-Agent' => 'ruby').read
  release = JSON.parse(json)
  major = macos_major_version
  asset = release['assets'].find do |a|
    a['name'].match?(/MacPorts-.*-#{Regexp.escape(major)}-.*\.pkg$/)
  end
  asset ? asset['browser_download_url'] : nil
rescue StandardError => e
  abort "Error: Could not fetch MacPorts release info: #{e.message}"
end

def install_macports(dry_run:)
  url = macports_pkg_url
  abort 'Error: Could not find a MacPorts .pkg for your macOS version.' unless url

  pkg = File.join(Dir.tmpdir, File.basename(url))
  if dry_run
    puts "  [dry-run] curl -fsSL #{url} -o #{pkg}"
    puts "  [dry-run] sudo installer -pkg #{pkg} -target /"
    return
  end

  puts "Downloading #{File.basename(url)}..."
  system('curl', '-fsSL', url, '-o', pkg)
  abort 'Error: MacPorts download failed.' unless $CHILD_STATUS.success?
  system('sudo', 'installer', '-pkg', pkg, '-target', '/')
  abort 'Error: MacPorts installation failed.' unless $CHILD_STATUS.success?
ensure
  File.delete(pkg) if pkg && File.exist?(pkg) && !dry_run
end
```

Note: `Dir.tmpdir` requires `require 'tmpdir'` — add that to the require block at the top.

**Step 3: Add `require 'tmpdir'` to the require block**

```ruby
require 'tmpdir'
```

**Step 4: Verify Ruby parses cleanly**

```bash
ruby -c install_macports_replacements.rb
```

Expected: `Syntax OK`

**Step 5: Commit**

```bash
git add install_macports_replacements.rb
git commit -m "feat: add Homebrew and MacPorts installer methods"
```

---

### Task 6: Add `resolve_package_manager`

**Files:**
- Modify: `install_macports_replacements.rb` (add after the installer methods)

**Step 1: Add `install_package_manager` and `resolve_package_manager`**

```ruby
def install_package_manager(pm, dry_run:)
  puts "Installing #{pm[:name]}..."
  if pm[:id] == :homebrew
    install_homebrew(dry_run: dry_run)
  else
    install_macports(dry_run: dry_run)
  end

  # Re-detect the binary at its known path after installation.
  bin = dry_run ? File.join(pm[:default_bin_dirs].first, pm[:bin_name]) : find_pm_binary(pm)
  abort "Error: #{pm[:name]} binary not found after installation." unless bin || dry_run

  pm.merge(bin: bin || File.join(pm[:default_bin_dirs].first, pm[:bin_name]))
end

def resolve_package_manager(options)
  available = detect_available_pms

  case available.size
  when 1
    pm = available.first
    puts "Using #{pm[:name]}."
    pm
  when 2
    labels = available.map { |p| p[:install_label] }
    idx = select_with_arrows('Select a package manager:', labels)
    puts
    available[idx]
  else
    # Neither installed — ask which to install.
    labels = PACKAGE_MANAGERS.map { |p| p[:install_label] }
    puts 'No package manager found.'
    idx = select_with_arrows('Select one to install:', labels)
    puts
    chosen = PACKAGE_MANAGERS[idx]
    installed_pm = install_package_manager(chosen, dry_run: options[:dry_run])
    puts "Using #{installed_pm[:name]}."
    installed_pm
  end
end
```

**Step 2: Verify Ruby parses cleanly**

```bash
ruby -c install_macports_replacements.rb
```

Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add install_macports_replacements.rb
git commit -m "feat: add resolve_package_manager orchestration"
```

---

### Task 7: Refactor PM-querying methods to be PM-agnostic

**Files:**
- Modify: `install_macports_replacements.rb`

**Step 1: Replace `port_installed_set` with `installed_pkg_set(pm)`**

Old:
```ruby
def port_installed_set
  output, status = Open3.capture2('port', 'installed')
  return Set.new unless status.success?

  output.lines.each_with_object(Set.new) do |line, set|
    match = line.match(/^\s+(\S+)\s/)
    set.add(match[1]) if match
  end
end
```

New:
```ruby
def installed_pkg_set(pm)
  if pm[:id] == :macports
    output, status = Open3.capture2(pm[:bin], 'installed')
    return Set.new unless status.success?

    output.lines.each_with_object(Set.new) do |line, set|
      match = line.match(/^\s+(\S+)\s/)
      set.add(match[1]) if match
    end
  else
    output, status = Open3.capture2(pm[:bin], 'list', '--formula')
    return Set.new unless status.success?

    output.lines.each_with_object(Set.new) { |line, set| set.add(line.strip) }
  end
end
```

**Step 2: Replace `parse_port_info_output` + `port_versions` with `pkg_versions(pm, pkg_names)`**

Remove `parse_port_info_output` and `port_versions` entirely. Add:

```ruby
def pkg_versions(pm, pkg_names)
  return {} if pkg_names.empty?

  if pm[:id] == :macports
    output, status = Open3.capture2(pm[:bin], 'info', '--version', '--name', *pkg_names)
    return {} unless status.success?

    versions = {}
    current_version = nil
    output.lines.each do |line|
      current_version = Regexp.last_match(1) if line.match(/^version:\s*(\S+)/)
      next unless (m = line.match(/^name:\s*(\S+)/)) && current_version

      versions[m[1]] = current_version
      current_version = nil
    end
    versions
  else
    output, status = Open3.capture2(pm[:bin], 'list', '--formula', '--versions', *pkg_names)
    return {} unless status.success?

    output.lines.each_with_object({}) do |line, h|
      parts = line.strip.split
      h[parts[0]] = parts[1] if parts.size >= 2
    end
  end
end
```

**Step 3: Update `print_tool_table` to accept and thread pm**

Old signature: `def print_tool_table(tools)`
New:
```ruby
def print_tool_table(tools, pm)
  pkg_names = tools.map { |t| t[pm[:pkg_key]] }.compact.uniq
  installed  = installed_pkg_set(pm)
  versions   = pkg_versions(pm, pkg_names)

  print_table_header(pm)
  tools.each do |tool|
    pkg = tool[pm[:pkg_key]]
    print_tool_row(tool, pm,
                   installed: pkg && installed.include?(pkg),
                   version: pkg && versions[pkg])
  end
end
```

**Step 4: Update `print_table_header` and `print_tool_row` to accept pm**

Old `print_table_header`:
```ruby
def print_table_header
  puts "     #{format(ROW_FMT, 'Tool', 'MacPorts Port', 'Xcode Version', 'MacPorts Version')}"
  puts "  #{'-' * (COL_WIDTHS.sum + 8)}"
end
```

New:
```ruby
def print_table_header(pm)
  pkg_col     = "#{pm[:name]} Package"
  version_col = "#{pm[:name]} Version"
  puts "     #{format(ROW_FMT, 'Tool', pkg_col, 'Xcode Version', version_col)}"
  puts "  #{'-' * (COL_WIDTHS.sum + 8)}"
end
```

Old `print_tool_row(tool, installed:, version:)`:
```ruby
def print_tool_row(tool, installed:, version:)
  port = tool['macports_port'] || '(none)'
  ...
end
```

New:
```ruby
def print_tool_row(tool, pm, installed:, version:)
  pkg = tool[pm[:pkg_key]] || '(none)'
  icon = installed ? "\u2705" : "\u274C"
  xcode_lines = wrap_text(tool['xcode_version'].to_s, COL_WIDTHS[2])

  puts "  #{icon} " + format(ROW_FMT, tool['name'], pkg, xcode_lines[0], version || '')
  xcode_lines[1..].each { |line| puts(' ' * WRAP_OFFSET) + line }
end
```

**Step 5: Verify Ruby parses cleanly**

```bash
ruby -c install_macports_replacements.rb
```

Expected: `Syntax OK`

**Step 6: Commit**

```bash
git add install_macports_replacements.rb
git commit -m "refactor: make query and display methods PM-agnostic"
```

---

### Task 8: Refactor install methods to be PM-agnostic

**Files:**
- Modify: `install_macports_replacements.rb`

**Step 1: Replace `needs_sudo?` with `needs_sudo_for?(pm)`**

Old:
```ruby
def needs_sudo?
  return @needs_sudo unless @needs_sudo.nil?

  port_bin = Open3.capture2('which', 'port').first.strip
  prefix = File.dirname(File.dirname(port_bin))
  @needs_sudo = !File.writable?(prefix)
end
```

New:
```ruby
def needs_sudo_for?(pm)
  return false unless pm[:needs_sudo]

  prefix = File.dirname(File.dirname(pm[:bin]))
  !File.writable?(prefix)
end
```

**Step 2: Replace `run_port_install` with `run_install(pm, pkgs, dry_run:)`**

Old:
```ruby
def run_port_install(ports, dry_run:)
  port_args = ['port', '-N', 'install']
  cmd = needs_sudo? ? ['sudo', *port_args, *ports] : [*port_args, *ports]
  if dry_run
    puts "  [dry-run] #{cmd.join(' ')}"
    return true
  end
  system(*cmd)
end
```

New:
```ruby
def run_install(pm, pkgs, dry_run:)
  cmd = if pm[:id] == :macports
          base = [pm[:bin], '-N', 'install']
          needs_sudo_for?(pm) ? ['sudo', *base, *pkgs] : [*base, *pkgs]
        else
          [pm[:bin], 'install', *pkgs]
        end

  if dry_run
    puts "  [dry-run] #{cmd.join(' ')}"
    return true
  end
  system(*cmd)
end
```

**Step 3: Update `do_install` to accept pm**

Old:
```ruby
def do_install(installable, options)
  ports = installable.map { |t| t['macports_port'] }.uniq
  puts
  success = run_port_install(ports, dry_run: options[:dry_run])
  puts
  puts '---'
  puts success ? "Installed #{ports.size} port(s)." : 'port install failed.'
end
```

New:
```ruby
def do_install(installable, options, pm)
  pkgs = installable.map { |t| t[pm[:pkg_key]] }.uniq
  puts
  success = run_install(pm, pkgs, dry_run: options[:dry_run])
  puts
  puts '---'
  puts success ? "Installed #{pkgs.size} package(s)." : "#{pm[:name]} install failed."
end
```

**Step 4: Verify Ruby parses cleanly**

```bash
ruby -c install_macports_replacements.rb
```

Expected: `Syntax OK`

**Step 5: Commit**

```bash
git add install_macports_replacements.rb
git commit -m "refactor: make install methods PM-agnostic"
```

---

### Task 9: Refactor `filter_tools` and update `main`

**Files:**
- Modify: `install_macports_replacements.rb`

**Step 1: Update `filter_tools` to use `pm[:pkg_key]`**

Old:
```ruby
def filter_tools(tools, options)
  installable = tools.select { |t| t['macports_port'] }
  installable = installable.select { |t| options[:tools].include?(t['name']) } if options[:tools]
  installable = installable.reject { |t| options[:skip].include?(t['name']) } unless options[:skip].empty?
  installable
end
```

New:
```ruby
def filter_tools(tools, options, pm)
  installable = tools.select { |t| t[pm[:pkg_key]] }
  installable = installable.select { |t| options[:tools].include?(t['name']) } if options[:tools]
  installable = installable.reject { |t| options[:skip].include?(t['name']) } unless options[:skip].empty?
  installable
end
```

**Step 2: Replace `verify_environment` with `verify_xcode_clt`**

Remove `verify_environment` entirely. Add:

```ruby
def verify_xcode_clt(inventory)
  clt_path = inventory.dig('metadata', 'xcode_clt_path')
  abort "Error: Xcode CLT path not found at #{clt_path}." unless clt_path && Dir.exist?(clt_path)

  puts "Xcode CLT path: #{clt_path}"
  puts "Tools in inventory: #{inventory['tools'].size}"
  puts
end
```

**Step 3: Update `main`**

Old:
```ruby
def main
  options = parse_options
  inventory = load_inventory
  verify_environment(inventory)

  installable = filter_tools(inventory['tools'], options)
  print_tool_table(installable)
  return if options[:list_only]

  abort 'Nothing to install.' if installable.empty?

  puts
  abort 'Aborted.' unless confirm_install(options)

  do_install(installable, options)
end
```

New:
```ruby
def main
  options   = parse_options
  inventory = load_inventory
  verify_xcode_clt(inventory)

  pm = resolve_package_manager(options)
  puts

  installable = filter_tools(inventory['tools'], options, pm)
  print_tool_table(installable, pm)
  return if options[:list_only]

  abort 'Nothing to install.' if installable.empty?

  puts
  abort 'Aborted.' unless confirm_install(options)

  do_install(installable, options, pm)
end
```

**Step 4: Verify Ruby parses cleanly**

```bash
ruby -c install_macports_replacements.rb
```

Expected: `Syntax OK`

**Step 5: Commit**

```bash
git add install_macports_replacements.rb
git commit -m "refactor: wire PM through main flow, extract verify_xcode_clt"
```

---

### Task 10: Integration verification

**Files:** None — read-only verification.

**Step 1: Run `--list` to verify table renders with the active PM**

```bash
ruby install_macports_replacements.rb --list
```

Expected: table prints with either "MacPorts Package" or "Homebrew Package" as the column header, matching whatever PM you have installed.

**Step 2: Run `--dry-run` to verify full flow without side effects**

```bash
ruby install_macports_replacements.rb --dry-run --assume-yes
```

Expected:
- "Using MacPorts." or "Using Homebrew." printed
- Table renders
- `[dry-run] port -N install ...` or `[dry-run] brew install ...` printed
- "Installed N package(s)." printed
- No actual installs happen

**Step 3: Verify `--tools` filter still works**

```bash
ruby install_macports_replacements.rb --dry-run --assume-yes --tools git,make
```

Expected: only `git` and `make` appear in the table and install command.

**Step 4: Commit if any fixups were needed; otherwise note success**

```bash
git add install_macports_replacements.rb
git commit -m "fix: integration fixups from manual verification"
```

(Skip this commit if no changes were needed.)
