#!/usr/bin/env ruby
# frozen_string_literal: true

require 'io/console'
require 'json'
require 'open3'
require 'open-uri'
require 'optparse'
require 'set'
require 'tmpdir'

INVENTORY_LOCAL = __dir__ ? File.join(__dir__, 'xcode_clt_tools.json') : nil
INVENTORY_URL = 'https://raw.githubusercontent.com/zadr/xcode-cli-supply-chain/main/xcode_clt_tools.json'
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
COL_WIDTHS = [16, 18, 36, 14].freeze
ROW_FMT = "%-#{COL_WIDTHS[0]}s %-#{COL_WIDTHS[1]}s %-#{COL_WIDTHS[2]}s %s"
WRAP_OFFSET = 5 + COL_WIDTHS[0] + COL_WIDTHS[1] + 2

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
  PACKAGE_MANAGERS.map { |pm|
    bin = find_pm_binary(pm)
    bin ? pm.merge(bin: bin) : nil
  }.compact
end

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
  lines = [prompt.to_s]
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
  $stdin.tty? ? arrow_key_menu(prompt, labels) : numbered_menu(prompt, labels)
end

def install_homebrew(dry_run:)
  cmd = '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  if dry_run
    puts "  [dry-run] #{cmd}"
    return
  end
  system(cmd)
end

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
    # MacPorts is the recommended default — it appears first in PACKAGE_MANAGERS
    # and therefore starts highlighted in the menu.
    labels = available.map { |p| p[:install_label] }
    idx = select_with_arrows('Select a package manager:', labels)
    puts
    available[idx]
  else
    # Neither installed — ask which to install.
    # MacPorts is the recommended default and starts highlighted (index 0).
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

def load_inventory
  data = if INVENTORY_LOCAL && File.exist?(INVENTORY_LOCAL)
           File.read(INVENTORY_LOCAL)
         else
           URI.parse(INVENTORY_URL).open.read
         end
  JSON.parse(data)
rescue JSON::ParserError => e
  abort "Error: Failed to parse inventory: #{e.message}"
end

def needs_sudo_for?(pm)
  return false unless pm[:needs_sudo]

  prefix = File.dirname(File.dirname(pm[:bin]))
  !File.writable?(prefix)
end

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

def append_word(lines, word, width)
  if lines.last.empty?
    lines[lines.size - 1] = word
  elsif lines.last.length + 1 + word.length <= width
    lines[lines.size - 1] += " #{word}"
  else
    lines << word
  end
end

def wrap_text(text, width)
  return [''] if text.nil? || text.empty?

  text.split(/\s+/).each_with_object(['']) { |word, lines| append_word(lines, word, width) }
end

def print_table_header(pm)
  pkg_col     = "#{pm[:name]} Package"
  version_col = "#{pm[:name]} Version"
  puts "     #{format(ROW_FMT, 'Tool', pkg_col, 'Xcode Version', version_col)}"
  puts "  #{'-' * (COL_WIDTHS.sum + 8)}"
end

def print_tool_row(tool, pm, installed:, version:)
  pkg = tool[pm[:pkg_key]] || '(none)'
  icon = installed ? "\u2705" : "\u274C"
  xcode_lines = wrap_text(tool['xcode_version'].to_s, COL_WIDTHS[2])

  puts "  #{icon} " + format(ROW_FMT, tool['name'], pkg, xcode_lines[0], version || '')

  xcode_lines[1..].each do |line|
    puts (' ' * WRAP_OFFSET) + line
  end
end

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

def parse_csv(value)
  value.split(',').map(&:strip)
end

def define_flags(opts, options)
  opts.on('-n', '--dry-run', 'Show what would be installed without doing it') { options[:dry_run] = true }
  opts.on('-l', '--list', 'List tools and their status, then exit') { options[:list_only] = true }
  opts.on('-y', '--assume-yes', 'Skip confirmation prompt') { options[:assume_yes] = true }
end

def define_filters(opts, options)
  opts.on('-t', '--tools TOOLS', 'Comma-separated list of tool names') { |t| options[:tools] = parse_csv(t) }
  opts.on('-s', '--skip TOOLS', 'Comma-separated list to skip') { |s| options[:skip] = parse_csv(s) }
  opts.on('-h', '--help', 'Show this help') { puts opts; exit } # rubocop:disable Style/Semicolon
end

def parse_options
  options = { dry_run: false, list_only: false, assume_yes: false, tools: nil, skip: [] }
  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"
    define_flags(opts, options)
    define_filters(opts, options)
  end.parse!
  options
end

def verify_xcode_clt(inventory)
  clt_path = inventory.dig('metadata', 'xcode_clt_path')
  unless clt_path && Dir.exist?(clt_path)
    puts "Note: Xcode CLT not found — proceeding to install replacements."
    puts
    return
  end

  puts "Xcode CLT path: #{clt_path}"
  puts "Tools in inventory: #{inventory['tools'].size}"
  puts
end

def filter_tools(tools, options, pm)
  installable = tools.select { |t| t[pm[:pkg_key]] }
  installable = installable.select { |t| options[:tools].include?(t['name']) } if options[:tools]
  installable = installable.reject { |t| options[:skip].include?(t['name']) } unless options[:skip].empty?
  installable
end

def confirm_install(options)
  return true if options[:dry_run] || options[:assume_yes]

  print 'Proceed? [y/N] '
  $stdin.gets&.strip&.match?(/\Ay(es)?\z/i)
end

def do_install(installable, options, pm)
  pkgs = installable.map { |t| t[pm[:pkg_key]] }.uniq
  puts
  success = run_install(pm, pkgs, dry_run: options[:dry_run])
  puts
  puts '---'
  puts success ? "Installed #{pkgs.size} package(s)." : "#{pm[:name]} install failed."
end

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

main
