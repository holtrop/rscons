#!/usr/bin/env ruby

require "bundler"
require "fileutils"
require "open3"
require "set"
require "tmpdir"
require "rscons"

BASE_DIR = File.expand_path("build_test_run")
OWD = Dir.pwd
TESTS_LINE = File.read(__FILE__).lines.find_index {|line| line.chomp == "# Tests"}

RunResults = Struct.new(:stdout, :stderr, :status)

class Test
  attr_reader :id
  attr_reader :name
  attr_accessor :output

  def initialize(desc, id, block)
    @desc = desc
    @id = id
    @name = "bt#{sprintf("%03d", @id)}"
    @run_dir = "#{BASE_DIR}/#{@name}"
    @block = block
    @coverage_dir = "#{OWD}/coverage/#{@name}"
    @output = ""
    @invocation = 0
  end

  def run(outfh)
    failure = false
    begin
      self.instance_eval(&@block)
      @output += "<pass>" if @output == ""
    rescue RuntimeError => re
      @output += re.message + "\n"
      # TODO:
      re.backtrace.each do |line|
        if line =~ %r{^(.*/#{File.basename(__FILE__)}:(\d+))}
          if $2.to_i > TESTS_LINE
            @output += "#{$1}\n"
          end
        end
      end
      @output += "Keeping directory #{@run_dir} for inspection"
      failure = true
    end
    unless failure
      rm_rf(@run_dir)
    end
    outfh.puts(@output) if outfh
  end

  def test_dir(build_test_directory)
    Dir.chdir(OWD)
    rm_rf(@run_dir)
    FileUtils.cp_r("build_tests/#{build_test_directory}", @run_dir)
    FileUtils.mkdir("#{@run_dir}/_bin")
    Dir.chdir(@run_dir)
  end

  def create_exe(exe_name, contents)
    exe_file = "#{@run_dir}/_bin/#{exe_name}"
    if RUBY_PLATFORM =~ /mingw/
      exe_file += ".bat"
    end
    File.open(exe_file, "wb") do |fh|
      fh.puts("#!/bin/sh")
      fh.puts(contents)
    end
    FileUtils.chmod(0755, exe_file)
  end

  def file_sub(fname)
    contents = File.read(fname)
    replaced = ''
    contents.each_line do |line|
      replaced += yield(line)
    end
    File.open(fname, 'wb') do |fh|
      fh.write(replaced)
    end
  end

  def run_rscons(options = {})
    @invocation += 1
    args = Array(options[:args]) || []
    if ENV["dist_specs"]
      exe = "#{OWD}/test_run/rscons.rb"
    else
      exe = "#{OWD}/bin/rscons"
    end
    command = %W[ruby -I. -r _simplecov_setup #{exe}] + args
    File.open("_simplecov_setup.rb", "w") do |fh|
      fh.puts <<EOF
unless ENV["dist_specs"]
require "bundler"
Bundler.setup
require "simplecov"
class MyFormatter
  def format(*args)
  end
end
SimpleCov.start do
  root(#{OWD.inspect})
  coverage_dir(#{@coverage_dir.inspect})
  command_name "#{@name}_#{@invocation}"
  filters.clear
  add_filter do |src|
    !(src.filename[SimpleCov.root])
  end
  formatter(MyFormatter)
end
end
# force color off
ENV["TERM"] = nil
EOF
      unless ENV["dist_specs"]
        fh.puts %[$LOAD_PATH.unshift(#{OWD.inspect} + "/lib")]
      end
    end
    stdout, stderr, status = nil, nil, nil
    Bundler.with_unbundled_env do
      env = ENV.to_h
      env.merge!(options[:env] || {})
      path = ["#{@run_dir}/_bin", "#{env["PATH"]}"]
      if options[:path]
        path = Array(options[:path]) + path
      end
      env["PATH"] = path.join(File::PATH_SEPARATOR)
      stdout, stderr, status = Open3.capture3(env, *command)
      File.binwrite("#{@run_dir}/.stdout", stdout)
      File.binwrite("#{@run_dir}/.stderr", stderr)
    end
    # Remove output lines generated as a result of the test environment
    stderr = stderr.lines.find_all do |line|
      not (line =~ /Warning: coverage data provided by Coverage.*exceeds number of lines|Stopped processing SimpleCov/)
    end.join
    RunResults.new(stdout, stderr, status)
  end

  def lines(str)
    str.lines.map(&:chomp)
  end

  def verify_lines(lines, patterns)
    patterns.each_with_index do |pattern, i|
      found_index =
        if pattern.is_a?(Regexp)
          lines.find_index {|line| line =~ pattern}
        else
          lines.find_index do |line|
            line.chomp == pattern.chomp
          end
        end
      unless found_index
        $stderr.puts "Lines:"
        $stderr.puts lines
        raise "A line matching #{pattern.inspect} (index #{i}) was not found."
      end
    end
  end

  def nr(str)
    str.gsub("\r", "")
  end

  def expect(a)
    unless a
      raise "Expected #{a.inspect}"
    end
  end

  def expect_eq(a, b)
    if a != b
      raise "Expected #{a.inspect} to equal #{b.inspect}"
    end
  end

  def expect_ne(a, b)
    if a == b
      raise "Expected #{a.inspect} to not equal #{b.inspect}"
    end
  end

  def expect_match(a, b)
    unless a =~ b
      raise "Expected #{a.inspect} to match #{b.inspect}"
    end
  end

  def expect_not_match(a, b)
    if a =~ b
      raise "Expected #{a.inspect} to not match #{b.inspect}"
    end
  end

  def expect_truthy(a)
    unless a
      raise "Expected #{a.inspect} to be truthy"
    end
  end

  def expect_falsey(a)
    if a
      raise "Expected #{a.inspect} to be falsey"
    end
  end

  def expect_match_array(a, b)
    unless a.sort == b.sort
      raise "Expected #{a.inspect} to match #{b.inspect}"
    end
  end
end

@tests = []
@focused_tests = []

def context(name, &block)
  block[]
end

def rm_rf(dir)
  FileUtils.rm_rf(dir)
  if File.exist?(dir)
    sleep 0.2
    FileUtils.rm_rf(dir)
    if File.exist?(dir)
      sleep 0.5
      FileUtils.rm_rf(dir)
      if File.exist?(dir)
        sleep 1.0
        FileUtils.rm_rf(dir)
        if File.exist?(dir)
          raise "Could not remove #{dir}"
        end
      end
    end
  end
end

def run_tests
  $stdout.sync = true
  rm_rf(BASE_DIR)
  FileUtils.mkdir_p(BASE_DIR)
  keep_run_dir = false
  tests = @focused_tests.size > 0 ? @focused_tests : @tests
  queue = Queue.new
  threads = {}
  n_procs = `nproc`.to_i * 2
  failure = false
  loop do
    break if threads.empty? && tests.empty?
    if threads.size >= n_procs || tests.empty?
      thread = queue.pop
      piper, pipew, test = threads[thread]
      pipew.close
      test.output = piper.read
      if test.output.start_with?("<pass>")
        Rscons::Ansi.write($stdout, :green, ".", :reset)
      else
        Rscons::Ansi.write($stdout, :red, "F", :reset, "\n")
        $stderr.write(test.output)
        failure = true
      end
      thread.join
      piper.close
      threads.delete(thread)
    end
    if test = tests.slice!(0)
      piper, pipew = IO.pipe
      thread = Thread.new do
        fork do
          piper.close
          test.run(pipew)
        end
        queue.push(Thread.current)
      end
      threads[thread] = [piper, pipew, test]
    end
  end
  $stdout.write("\n")
  unless failure
    rm_rf(BASE_DIR)
  end
end

def test(name, &block)
  test = Test.new(name, @tests.size, block)
  @tests << test
  test
end

def ftest(name, &block)
  @focused_tests << test(name, &block)
end

###########################################################################
# Tests
###########################################################################

test 'builds a C program with one source file' do
  test_dir('simple')
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?('build/o/simple.c.o'))
  expect_eq(nr(`./simple.exe`), "This is a simple C program\n")
end

test "processes the environment when created within a task" do
  test_dir("simple")
  result = run_rscons(args: %w[-f env_in_task.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("build/o/simple.c.o"))
  expect_eq(nr(`./simple.exe`), "This is a simple C program\n")
end

test "uses the build directory specified with -b" do
  test_dir("simple")
  result = run_rscons(args: %w[-b b])
  expect_eq(result.stderr, "")
  expect_falsey(Dir.exist?("build"))
  expect_truthy(File.exist?("b/o/simple.c.o"))
end

test "uses the build directory specified by an environment variable" do
  test_dir("simple")
  result = run_rscons(env: {"RSCONS_BUILD_DIR" => "b2"})
  expect_eq(result.stderr, "")
  expect_falsey(Dir.exist?("build"))
  expect_truthy(File.exist?("b2/o/simple.c.o"))
end

test "allows specifying a Builder object as the source to another build target" do
  test_dir("simple")
  result = run_rscons(args: %w[-f builder_as_source.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("simple.o"))
  expect_eq(nr(`./simple.exe`), "This is a simple C program\n")
end

test 'prints commands as they are executed' do
  test_dir('simple')
  result = run_rscons(args: %w[-f command.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o build/o/simple.c.o -MMD -MF build/o/simple.c.o.mf simple.c},
    %r{gcc -o simple.exe build/o/simple.c.o},
  ])
end

test 'prints short representations of the commands being executed' do
  test_dir('header')
  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling header.c},
    %r{Linking header.exe},
  ])
end

test 'builds a C program with one source file and one header file' do
  test_dir('header')
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?('build/o/header.c.o'))
  expect_eq(nr(`./header.exe`), "The value is 2\n")
end

test 'rebuilds a C module when a header it depends on changes' do
  test_dir('header')
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_eq(nr(`./header.exe`), "The value is 2\n")
  file_sub('header.h') {|line| line.sub(/2/, '5')}
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_eq(nr(`./header.exe`), "The value is 5\n")
end

test 'does not rebuild a C module when its dependencies have not changed' do
  test_dir('header')
  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling header.c},
    %r{Linking header.exe},
  ])
  expect_eq(nr(`./header.exe`), "The value is 2\n")
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_eq(result.stdout, "")
end

test "does not rebuild a C module when only the file's timestamp has changed" do
  test_dir('header')
  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling header.c},
    %r{Linking header.exe},
  ])
  expect_eq(nr(`./header.exe`), "The value is 2\n")
  sleep 0.05
  file_sub('header.c') {|line| line}
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_eq(result.stdout, "")
end

test 're-links a program when the link flags have changed' do
  test_dir('simple')
  result = run_rscons(args: %w[-f command.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o build/o/simple.c.o -MMD -MF build/o/simple.c.o.mf simple.c},
    %r{gcc -o simple.exe build/o/simple.c.o},
  ])
  result = run_rscons(args: %w[-f link_flag_change.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -o simple.exe build/o/simple.c.o -Llibdir},
  ])
end

test "supports barriers and prevents parallelizing builders across them" do
  test_dir "simple"
  result = run_rscons(args: %w[-f barrier.rb -j 3])
  expect_eq(result.stderr, "")
  slines = lines(result.stdout).select {|line| line =~ /T\d/}
  expect_eq(slines, [
    "[1/6] ThreadedTestBuilder T3",
    "[2/6] ThreadedTestBuilder T2",
    "[3/6] ThreadedTestBuilder T1",
    "T1 finished",
    "T2 finished",
    "T3 finished",
    "[4/6] ThreadedTestBuilder T6",
    "[5/6] ThreadedTestBuilder T5",
    "[6/6] ThreadedTestBuilder T4",
    "T4 finished",
    "T5 finished",
    "T6 finished",
  ])
end

test "expands target and source paths starting with ^/ and ^^/" do
  test_dir("typical")
  result = run_rscons(args: %w[-f carat.rb -b bld])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o bld/one.o -MMD -MF bld/one.o.mf -Isrc -Isrc/one -Isrc/two bld/one.c},
    %r{gcc -c -o bld/two.c.o -MMD -MF bld/two.c.o.mf -Isrc -Isrc/one -Isrc/two bld/two.c},
    %r{gcc -o bld/program.exe bld/one.o bld/two.c.o},
  ])
end

test 'supports simple builders' do
  test_dir('json_to_yaml')
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?('foo.yml'))
  expect_eq(nr(IO.read('foo.yml')), "---\nkey: value\n")
end

test "raises an error when a side-effect file is registered for a build target that is not registered" do
  test_dir "simple"
  result = run_rscons(args: %w[-f error_produces_nonexistent_target.rb])
  expect_match(result.stderr, /Could not find a registered build target "foo"/)
end

context "clean task" do
  test 'cleans built files' do
    test_dir("simple")
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_match(`./simple.exe`, /This is a simple C program/)
    expect_truthy(File.exist?('build/o/simple.c.o'))
    result = run_rscons(args: %w[clean])
    expect_falsey(File.exist?('build/o/simple.c.o'))
    expect_falsey(File.exist?('build/o'))
    expect_falsey(File.exist?('simple.exe'))
    expect_truthy(File.exist?('simple.c'))
  end

  test "executes custom clean action blocks" do
    test_dir("simple")
    result = run_rscons(args: %w[-f clean.rb])
    expect_eq(result.stderr, "")
    expect_truthy(File.exist?("build/o/simple.c.o"))
    result = run_rscons(args: %w[-f clean.rb clean])
    expect_eq(result.stderr, "")
    expect_match(result.stdout, %r{custom clean action})
    expect_falsey(File.exist?("build/o/simple.c.o"))
  end

  test "does not process environments" do
    test_dir("simple")
    result = run_rscons(args: %w[clean])
    expect_eq(result.stderr, "")
    expect_falsey(File.exist?('build/o/simple.c.o'))
    expect_falsey(File.exist?('build/o'))
    expect_falsey(File.exist?('simple.exe'))
    expect_truthy(File.exist?('simple.c'))
    expect_eq(result.stdout, "")
  end

  test 'does not clean created directories if other non-rscons-generated files reside there' do
    test_dir("simple")
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_match(`./simple.exe`, /This is a simple C program/)
    expect_truthy(File.exist?('build/o/simple.c.o'))
    File.open('build/o/dum', 'w') { |fh| fh.puts "dum" }
    result = run_rscons(args: %w[clean])
    expect_truthy(File.exist?('build/o'))
    expect_truthy(File.exist?('build/o/dum'))
  end

  test "removes built files but not installed files" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")
      expect_truthy(File.exist?("#{prefix}/bin/program.exe"))
      expect_truthy(File.exist?("build/o/src/one/one.c.o"))

      result = run_rscons(args: %w[-f install.rb clean])
      expect_eq(result.stderr, "")
      expect_truthy(File.exist?("#{prefix}/bin/program.exe"))
      expect_falsey(File.exist?("build/o/src/one/one.c.o"))
    end
  end

  test "does not remove install cache entries" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb clean])
      expect_eq(result.stderr, "")
      expect_truthy(File.exist?("#{prefix}/bin/program.exe"))
      expect_falsey(File.exist?("build/o/src/one/one.c.o"))

      result = run_rscons(args: %w[-f install.rb -v uninstall])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, %r{Removing #{prefix}/bin/program.exe})
      expect_match_array(Dir.entries(prefix), %w[. ..])
    end
  end
end

test 'allows Ruby classes as custom builders to be used to construct files' do
  test_dir('custom_builder')
  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling program.c},
    %r{Linking program.exe},
  ])
  expect_truthy(File.exist?('inc.h'))
  expect_eq(nr(`./program.exe`), "The value is 5678\n")
end

test 'supports custom builders with multiple targets' do
  test_dir('custom_builder')
  result = run_rscons(args: %w[-f multiple_targets.rb])
  expect_eq(result.stderr, "")
  slines = lines(result.stdout)
  verify_lines(slines, [
    %r{CHGen inc.c},
    %r{Compiling program.c},
    %r{Compiling inc.c},
    %r{Linking program.exe},
  ])
  expect_truthy(File.exist?("inc.c"))
  expect_truthy(File.exist?("inc.h"))
  expect_eq(nr(`./program.exe`), "The value is 42\n")

  File.open("inc.c", "w") {|fh| fh.puts "int THE_VALUE = 33;"}
  result = run_rscons(args: %w[-f multiple_targets.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [%r{CHGen inc.c}])
  expect_eq(nr(`./program.exe`), "The value is 42\n")
end

test 'raises an error when a custom builder returns an invalid value from #run' do
  test_dir("custom_builder")
  result = run_rscons(args: %w[-f error_run_return_value.rb])
  expect_match(result.stderr, /Unrecognized MyBuilder builder return value: "hi"/)
  expect_ne(result.status, 0)
end

test 'raises an error when a custom builder returns an invalid value using Builder#wait_for' do
  test_dir("custom_builder")
  result = run_rscons(args: %w[-f error_wait_for.rb])
  expect_match(result.stderr, /Unrecognized MyBuilder builder return item: 1/)
  expect_ne(result.status, 0)
end

test 'supports a Builder waiting for a custom Thread object' do
  test_dir "custom_builder"
  result = run_rscons(args: %w[-f wait_for_thread.rb])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  verify_lines(lines(result.stdout), [%r{MyBuilder foo}])
  expect_truthy(File.exist?("foo"))
end

test 'supports a Builder waiting for another Builder' do
  test_dir "simple"
  result = run_rscons(args: %w[-f builder_wait_for_builder.rb])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  verify_lines(lines(result.stdout), [%r{MyObject simple.o}])
  expect_truthy(File.exist?("simple.o"))
  expect_truthy(File.exist?("simple.exe"))
end

test 'allows cloning Environment objects' do
  test_dir('clone_env')
  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o build/dbg/o/src/program.c.o -MMD -MF build/dbg/o/src/program.c.o.mf '-DSTRING="Debug Version"' -O2 src/program.c},
    %r{gcc -o program-debug.exe build/dbg/o/src/program.c.o},
    %r{gcc -c -o build/rls/o/src/program.c.o -MMD -MF build/rls/o/src/program.c.o.mf '-DSTRING="Release Version"' -O2 src/program.c},
    %r{gcc -o program-release.exe build/rls/o/src/program.c.o},
  ])
end

test 'clones all attributes of an Environment object by default' do
  test_dir('clone_env')
  result = run_rscons(args: %w[-f clone_all.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o build/e1/o/src/program.c.o -MMD -MF build/e1/o/src/program.c.o.mf -DSTRING="Hello" -O2 src/program.c},
    %r{post build/e1/o/src/program.c.o},
    %r{gcc -o program.exe build/e1/o/src/program.c.o},
    %r{post program.exe},
    %r{post build/e2/o/src/program.c.o},
    %r{gcc -o program2.exe build/e2/o/src/program.c.o},
    %r{post program2.exe},
  ])
end

test 'builds a C++ program with one source file' do
  test_dir('simple_cc')
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?('build/o/simple.cc.o'))
  expect_eq(nr(`./simple.exe`), "This is a simple C++ program\n")
end

test "links with the C++ linker when object files were built from C++ sources" do
  test_dir("simple_cc")
  result = run_rscons(args: %w[-f link_objects.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("simple.o"))
  expect_eq(nr(`./simple.exe`), "This is a simple C++ program\n")
end

test 'allows overriding construction variables for individual builder calls' do
  test_dir('two_sources')
  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o one.o -MMD -MF build/o/one.o.mf -DONE one.c},
    %r{gcc -c -o build/o/two.c.o -MMD -MF build/o/two.c.o.mf two.c},
    %r{gcc -o two_sources.exe one.o build/o/two.c.o},
  ])
  expect_truthy(File.exist?("two_sources.exe"))
  expect_eq(nr(`./two_sources.exe`), "This is a C program with two sources.\n")
end

test 'builds a static library archive' do
  test_dir('library')
  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o build/o/two.c.o -MMD -MF build/o/two.c.o.mf -Dmake_lib two.c},
    %r{gcc -c -o build/o/three.c.o -MMD -MF build/o/three.c.o.mf -Dmake_lib three.c},
    %r{ar rcs libmylib.a build/o/two.c.o build/o/three.c.o},
    %r{gcc -c -o build/o/one.c.o -MMD -MF build/o/one.c.o.mf one.c},
    %r{gcc -o library.exe build/o/one.c.o -L. -lmylib},
  ])
  expect_truthy(File.exist?("library.exe"))
  ar_t = nr(`ar t libmylib.a`)
  expect_match(ar_t, %r{\btwo.c.o\b})
  expect_match(ar_t, %r{\bthree.c.o\b})
end

test 'supports build hooks to override construction variables' do
  test_dir("typical")
  result = run_rscons(args: %w[-f build_hooks.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o build/o/src/one/one.c.o -MMD -MF build/o/src/one/one.c.o.mf -Isrc/one -Isrc/two -O1 src/one/one.c},
    %r{gcc -c -o build/o/src/two/two.c.o -MMD -MF build/o/src/two/two.c.o.mf -Isrc/one -Isrc/two -O2 src/two/two.c},
    %r{gcc -o build_hook.exe build/o/src/one/one.c.o build/o/src/two/two.c.o},
  ])
  expect_eq(nr(`./build_hook.exe`), "Hello from two()\n")
end

test 'supports build hooks to override the entire vars hash' do
  test_dir("typical")
  result = run_rscons(args: %w[-f build_hooks_override_vars.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{gcc -c -o one.o -MMD -MF build/o/one.o.mf -Isrc -Isrc/one -Isrc/two -O1 src/two/two.c},
    %r{gcc -c -o two.o -MMD -MF build/o/two.o.mf -Isrc -Isrc/one -Isrc/two -O2 src/two/two.c},
  ])
  expect_truthy(File.exist?('one.o'))
  expect_truthy(File.exist?('two.o'))
end

test 'rebuilds when user-specified dependencies change' do
  test_dir('simple')

  File.open("program.ld", "w") {|fh| fh.puts("1")}
  result = run_rscons(args: %w[-f user_dependencies.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling simple.c},
    %r{Linking simple.exe},
  ])
  expect_truthy(File.exist?('build/o/simple.c.o'))
  expect_eq(nr(`./simple.exe`), "This is a simple C program\n")

  File.open("program.ld", "w") {|fh| fh.puts("2")}
  result = run_rscons(args: %w[-f user_dependencies.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [%r{Linking simple.exe}])

  File.unlink("program.ld")
  result = run_rscons(args: %w[-f user_dependencies.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [%r{Linking simple.exe}])

  result = run_rscons(args: %w[-f user_dependencies.rb])
  expect_eq(result.stderr, "")
  expect_eq(result.stdout, "")
end

test "rebuilds when user-specified dependencies using ^ change" do
  test_dir("simple")

  result = run_rscons(args: %w[-f user_dependencies_carat.rb], env: {"file_contents" => "1"})
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling simple.c},
    %r{Linking .*simple.exe},
  ])

  result = run_rscons(args: %w[-f user_dependencies_carat.rb], env: {"file_contents" => "2"})
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [%r{Linking .*simple.exe}])

  result = run_rscons(args: %w[-f user_dependencies_carat.rb], env: {"file_contents" => "2"})
  expect_eq(result.stderr, "")
  expect_eq(result.stdout, "")
end

unless RUBY_PLATFORM =~ /mingw|msys|darwin/
  test "supports building D sources with gdc" do
    test_dir("d")
    result = run_rscons
    expect_eq(result.stderr, "")
    slines = lines(result.stdout)
    verify_lines(slines, [%r{gdc -c -o build/o/main.d.o -MMD -MF build/o/main.d.o.mf main.d}])
    verify_lines(slines, [%r{gdc -c -o build/o/mod.d.o -MMD -MF build/o/mod.d.o.mf mod.d}])
    verify_lines(slines, [%r{gdc -o hello-d.exe build/o/main.d.o build/o/mod.d.o}])
    expect_eq(`./hello-d.exe`.rstrip, "Hello from D, value is 42!")
  end
end

test "supports building D sources with ldc2" do
  test_dir("d")
  result = run_rscons(args: %w[-f build-ldc2.rb])
  expect_eq(result.stderr, "")
  slines = lines(result.stdout)
  verify_lines(slines, [%r{ldc2 -c -of build/o/main.d.o(bj)? -deps=build/o/main.d.o(bj)?.mf main.d}])
  verify_lines(slines, [%r{ldc2 -c -of build/o/mod.d.o(bj)? -deps=build/o/mod.d.o(bj)?.mf mod.d}])
  verify_lines(slines, [%r{ldc2 -of hello-d.exe build/o/main.d.o(bj)? build/o/mod.d.o(bj)?}])
  expect_eq(`./hello-d.exe`.rstrip, "Hello from D, value is 42!")
end

test "rebuilds D modules with ldc2 when deep dependencies change" do
  test_dir("d")
  result = run_rscons(args: %w[-f build-ldc2.rb])
  expect_eq(result.stderr, "")
  slines = lines(result.stdout)
  verify_lines(slines, [%r{ldc2 -c -of build/o/main.d.o(bj)? -deps=build/o/main.d.o(bj)?.mf main.d}])
  verify_lines(slines, [%r{ldc2 -c -of build/o/mod.d.o(bj)? -deps=build/o/mod.d.o(bj)?.mf mod.d}])
  verify_lines(slines, [%r{ldc2 -of hello-d.exe build/o/main.d.o(bj)? build/o/mod.d.o(bj)?}])
  expect_eq(`./hello-d.exe`.rstrip, "Hello from D, value is 42!")
  contents = File.read("mod.d", mode: "rb").sub("42", "33")
  File.open("mod.d", "wb") do |fh|
    fh.write(contents)
  end
  result = run_rscons(args: %w[-f build-ldc2.rb])
  expect_eq(result.stderr, "")
  slines = lines(result.stdout)
  verify_lines(slines, [%r{ldc2 -c -of build/o/main.d.o(bj)? -deps=build/o/main.d.o(bj)?.mf main.d}])
  verify_lines(slines, [%r{ldc2 -c -of build/o/mod.d.o(bj)? -deps=build/o/mod.d.o(bj)?.mf mod.d}])
  verify_lines(slines, [%r{ldc2 -of hello-d.exe build/o/main.d.o(bj)? build/o/mod.d.o(bj)?}])
  expect_eq(`./hello-d.exe`.rstrip, "Hello from D, value is 33!")
end

unless RUBY_PLATFORM =~ /mingw|msys|darwin/
  test "links with the D linker when object files were built from D sources" do
    test_dir("d")
    result = run_rscons(args: %w[-f link_objects.rb])
    expect_eq(result.stderr, "")
    expect_truthy(File.exist?("main.o"))
    expect_truthy(File.exist?("mod.o"))
    expect_eq(`./hello-d.exe`.rstrip, "Hello from D, value is 42!")
  end

  test "does dependency generation for D sources" do
    test_dir("d")
    result = run_rscons
    expect_eq(result.stderr, "")
    slines = lines(result.stdout)
    verify_lines(slines, [%r{gdc -c -o build/o/main.d.o -MMD -MF build/o/main.d.o.mf main.d}])
    verify_lines(slines, [%r{gdc -c -o build/o/mod.d.o -MMD -MF build/o/mod.d.o.mf mod.d}])
    verify_lines(slines, [%r{gdc -o hello-d.exe build/o/main.d.o build/o/mod.d.o}])
    expect_eq(`./hello-d.exe`.rstrip, "Hello from D, value is 42!")
    fcontents = File.read("mod.d", mode: "rb").sub("42", "33")
    File.open("mod.d", "wb") {|fh| fh.write(fcontents)}
    result = run_rscons
    expect_eq(result.stderr, "")
    slines = lines(result.stdout)
    verify_lines(slines, [%r{gdc -c -o build/o/main.d.o -MMD -MF build/o/main.d.o.mf main.d}])
    verify_lines(slines, [%r{gdc -c -o build/o/mod.d.o -MMD -MF build/o/mod.d.o.mf mod.d}])
    verify_lines(slines, [%r{gdc -o hello-d.exe build/o/main.d.o build/o/mod.d.o}])
    expect_eq(`./hello-d.exe`.rstrip, "Hello from D, value is 33!")
  end

  test "creates shared libraries using D" do
    test_dir("shared_library")

    result = run_rscons(args: %w[-f shared_library_d.rb])
    expect_eq(result.stderr, "")
    slines = lines(result.stdout)
    if RUBY_PLATFORM =~ /mingw|msys/
      verify_lines(slines, [%r{Linking mine.dll}])
    else
      verify_lines(slines, [%r{Linking libmine.so}])
    end
  end
end

test "supports disassembling object files" do
  test_dir("simple")

  result = run_rscons(args: %w[-f disassemble.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("simple.txt"))
  expect_match(File.read("simple.txt"), /Disassembly of section/)

  result = run_rscons(args: %w[-f disassemble.rb])
  expect_eq(result.stderr, "")
  expect_eq(result.stdout, "")
end

test "supports preprocessing C sources" do
  test_dir("simple")
  result = run_rscons(args: %w[-f preprocess.rb])
  expect_eq(result.stderr, "")
  expect_match(File.read("simplepp.c"), /# \d+ "simple.c"/)
  expect_eq(nr(`./simple.exe`), "This is a simple C program\n")
end

test "supports preprocessing C++ sources" do
  test_dir("simple_cc")
  result = run_rscons(args: %w[-f preprocess.rb])
  expect_eq(result.stderr, "")
  expect_match(File.read("simplepp.cc"), /# \d+ "simple.cc"/)
  expect_eq(nr(`./simple.exe`), "This is a simple C++ program\n")
end

test "supports invoking builders with no sources" do
  test_dir("simple")
  result = run_rscons(args: %w[-f builder_no_sources.rb])
  expect_eq(result.stderr, "")
end

test "expands construction variables in builder target and sources before invoking the builder" do
  test_dir('custom_builder')
  result = run_rscons(args: %w[-f cvar_expansion.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling program.c},
    %r{Linking program.exe},
  ])
  expect_truthy(File.exist?('inc.h'))
  expect_eq(nr(`./program.exe`), "The value is 678\n")
end

test "supports lambdas as construction variable values" do
  test_dir "custom_builder"
  result = run_rscons(args: %w[-f cvar_lambda.rb])
  expect_eq(result.stderr, "")
  expect_eq(nr(`./program.exe`), "The value is 5678\n")
end

test "supports registering build targets from within a build hook" do
  test_dir("simple")
  result = run_rscons(args: %w[-f register_target_in_build_hook.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("build/o/simple.c.o"))
  expect_truthy(File.exist?("build/o/simple.c.o.txt"))
  expect_eq(nr(`./simple.exe`), "This is a simple C program\n")
end

test "supports multiple values for CXXSUFFIX" do
  test_dir("simple_cc")
  File.open("other.cccc", "w") {|fh| fh.puts}
  result = run_rscons(args: %w[-f cxxsuffix.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("build/o/simple.cc.o"))
  expect_truthy(File.exist?("build/o/other.cccc.o"))
  expect_eq(nr(`./simple.exe`), "This is a simple C++ program\n")
end

test "supports multiple values for CSUFFIX" do
  test_dir("typical")
  FileUtils.mv("src/one/one.c", "src/one/one.yargh")
  result = run_rscons(args: %w[-f csuffix.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("build/o/src/one/one.yargh.o"))
  expect_truthy(File.exist?("build/o/src/two/two.c.o"))
  expect_eq(nr(`./program.exe`), "Hello from two()\n")
end

test "supports multiple values for OBJSUFFIX" do
  test_dir("two_sources")
  result = run_rscons(args: %w[-f objsuffix.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("two_sources.exe"))
  expect_truthy(File.exist?("one.oooo"))
  expect_truthy(File.exist?("two.ooo"))
  expect_eq(nr(`./two_sources.exe`), "This is a C program with two sources.\n")
end

test "supports multiple values for LIBSUFFIX" do
  test_dir("two_sources")
  result = run_rscons(args: %w[-f libsuffix.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("two_sources.exe"))
  expect_eq(nr(`./two_sources.exe`), "This is a C program with two sources.\n")
end

test "supports multiple values for ASSUFFIX" do
  test_dir("two_sources")
  result = run_rscons(args: %w[-f assuffix.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling one.c},
    %r{Compiling two.c},
    %r{Assembling one.ssss},
    %r{Assembling two.sss},
    %r{Linking two_sources.exe},
  ])
  expect_truthy(File.exist?("two_sources.exe"))
  expect_eq(nr(`./two_sources.exe`), "This is a C program with two sources.\n")
end

test "supports dumping an Environment's construction variables" do
  test_dir("simple")
  result = run_rscons(args: %w[-f dump.rb])
  expect_eq(result.stderr, "")
  slines = lines(result.stdout)
  expect_truthy(slines.include?(%{:foo => :bar}))
  expect_truthy(slines.include?(%{CFLAGS => ["-O2", "-fomit-frame-pointer"]}))
  expect_truthy(slines.include?(%{CPPPATH => []}))
end

test "considers deep dependencies when deciding whether to rerun Preprocess builder" do
  test_dir("preprocess")

  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [%r{Preprocessing foo.h => pp}])
  expect_match(File.read("pp"), %r{xyz42abc}m)

  result = run_rscons
  expect_eq(result.stderr, "")
  expect_eq(result.stdout, "")

  File.open("bar.h", "w") do |fh|
    fh.puts "#define BAR abc88xyz"
  end
  result = run_rscons
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [%r{Preprocessing foo.h => pp}])
  expect_match(File.read("pp"), %r{abc88xyz}m)
end

test "allows construction variable references which expand to arrays in sources of a build target" do
  test_dir("simple")
  result = run_rscons(args: %w[-f cvar_array.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("build/o/simple.c.o"))
  expect_eq(nr(`./simple.exe`), "This is a simple C program\n")
end

test "supports registering multiple build targets with the same target path" do
  test_dir("typical")
  result = run_rscons(args: %w[-f multiple_targets_same_name.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("one.o"))
  verify_lines(lines(result.stdout), [
    %r{Compiling src/one/one.c},
    %r{Compiling src/two/two.c},
  ])
end

test "expands target and source paths when builders are registered in build hooks" do
  test_dir("typical")
  result = run_rscons(args: %w[-f post_build_hook_expansion.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("one.o"))
  expect_truthy(File.exist?("two.o"))
  verify_lines(lines(result.stdout), [
    %r{Compiling src/one/one.c},
    %r{Compiling src/two/two.c},
  ])
end

test "does not re-run previously successful builders if one fails" do
  test_dir('simple')
  File.open("two.c", "w") do |fh|
    fh.puts("FOO")
  end
  result = run_rscons(args: %w[-f cache_successful_builds_when_one_fails.rb -j1])
  expect_match(result.stderr, /FOO/)
  expect_truthy(File.exist?("simple.o"))
  expect_falsey(File.exist?("two.o"))

  File.open("two.c", "w") {|fh|}
  result = run_rscons(args: %w[-f cache_successful_builds_when_one_fails.rb -j1])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling two.c},
  ])
end

test "allows overriding PROGSUFFIX" do
  test_dir("simple")
  result = run_rscons(args: %w[-f progsuffix.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling simple.c},
    %r{Linking simple.out},
  ])
end

test "does not use PROGSUFFIX when the Program target name expands to a value already containing an extension" do
  test_dir("simple")
  result = run_rscons(args: %w[-f progsuffix2.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling simple.c},
    %r{Linking simple.out},
  ])
end

test "allows overriding PROGSUFFIX from extra vars passed in to the builder" do
  test_dir("simple")
  result = run_rscons(args: %w[-f progsuffix3.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [
    %r{Compiling simple.c},
    %r{Linking simple.xyz},
  ])
end

test "creates object files under the build root for absolute source paths" do
  test_dir("simple")
  result = run_rscons(args: %w[-f absolute_source_path.rb])
  expect_eq(result.stderr, "")
  slines = lines(result.stdout)
  verify_lines(slines, [%r{build/o/.*/abs\.c.o$}])
  verify_lines(slines, [%r{\babs.exe\b}])
end

test "creates object files next to the source file for source files in the build root" do
  test_dir "simple"
  result = run_rscons(args: %w[-f build_root_source_path.rb])
  expect_eq(result.stderr, "")
  expect_falsey(File.exist?("build/e/o/build/e/src/foo.c.o"))
  expect_truthy(File.exist?("build/e/src/foo.c.o"))
end

test "creates shared libraries" do
  test_dir("shared_library")

  result = run_rscons
  expect_eq(result.stderr, "")
  slines = lines(result.stdout)
  if RUBY_PLATFORM =~ /mingw|msys/
    verify_lines(slines, [%r{Linking mine.dll}])
    expect_truthy(File.exist?("mine.dll"))
  else
    verify_lines(slines, [%r{Linking libmine.so}])
    expect_truthy(File.exist?("libmine.so"))
  end

  result = run_rscons
  expect_eq(result.stderr, "")
  expect_eq(result.stdout, "")

  ld_library_path_prefix = (RUBY_PLATFORM =~ /mingw|msys/ ? "" : "LD_LIBRARY_PATH=. ")
  expect_match(`#{ld_library_path_prefix}./test-shared.exe`, /Hi from one/)
  expect_match(`./test-static.exe`, /Hi from one/)
end

test "creates shared libraries using assembly" do
  test_dir("shared_library")

  result = run_rscons(args: %w[-f shared_library_as.rb])
  expect_eq(result.stderr, "")
  expect_truthy(File.exist?("file.S"))
end

test "creates shared libraries using C++" do
  test_dir("shared_library")

  result = run_rscons(args: %w[-f shared_library_cxx.rb])
  expect_eq(result.stderr, "")
  slines = lines(result.stdout)
  if RUBY_PLATFORM =~ /mingw|msys/
    verify_lines(slines, [%r{Linking mine.dll}])
  else
    verify_lines(slines, [%r{Linking libmine.so}])
  end

  result = run_rscons(args: %w[-f shared_library_cxx.rb])
  expect_eq(result.stderr, "")
  expect_eq(result.stdout, "")

  ld_library_path_prefix = (RUBY_PLATFORM =~ /mingw|msys/ ? "" : "LD_LIBRARY_PATH=. ")
  expect_match(`#{ld_library_path_prefix}./test-shared.exe`, /Hi from one/)
  expect_match(`./test-static.exe`, /Hi from one/)
end

test "raises an error for a circular dependency" do
  test_dir("simple")
  result = run_rscons(args: %w[-f error_circular_dependency.rb])
  expect_match(result.stderr, /Possible circular dependency for (foo|bar|baz)/)
  expect_ne(result.status, 0)
end

test "raises an error for a circular dependency where a build target contains itself in its source list" do
  test_dir("simple")
  result = run_rscons(args: %w[-f error_circular_dependency2.rb])
  expect_match(result.stderr, /Possible circular dependency for foo/)
  expect_ne(result.status, 0)
end

test "orders builds to respect user dependencies" do
  test_dir("simple")
  result = run_rscons(args: %w[-f user_dep_build_order.rb -j4])
  expect_eq(result.stderr, "")
end

test "waits for all parallelized builds to complete if one fails" do
  test_dir("simple")
  result = run_rscons(args: %w[-f wait_for_builds_on_failure.rb -j4])
  expect_ne(result.status, 0)
  expect_match(result.stderr, /Failed to build foo_1/)
  expect_match(result.stderr, /Failed to build foo_2/)
  expect_match(result.stderr, /Failed to build foo_3/)
  expect_match(result.stderr, /Failed to build foo_4/)
end

test "clones n_threads attribute when cloning an Environment" do
  test_dir("simple")
  result = run_rscons(args: %w[-f clone_n_threads.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [/165/])
end

test "prints a builder's short description with 'command' echo mode if there is no command" do
  test_dir("typical")

  result = run_rscons(args: %w[-f echo_command_ruby_builder.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [%r{Copy echo_command_ruby_builder.rb => copy.rb}])
end

test "supports a string for a builder's echoed 'command' with Environment#print_builder_run_message" do
  test_dir("typical")

  result = run_rscons(args: %w[-f echo_command_string.rb])
  expect_eq(result.stderr, "")
  verify_lines(lines(result.stdout), [%r{MyBuilder foo command}])
end

test "stores the failed command for later display with -F command line option" do
  test_dir("simple")

  File.open("simple.c", "wb") do |fh|
    fh.write("foo")
  end

  result = run_rscons
  expect_match(result.stderr, /Failed to build/)
  expect_match(result.stderr, %r{^Use .*/rscons(\.rb)? -F.*to view the failed command log})
  expect_ne(result.status, 0)

  result = run_rscons(args: %w[-F])
  expect_eq(result.stderr, "")
  expect_match(result.stdout, %r{Failed command \(1/1\):})
  expect_match(result.stdout, %r{^gcc -})
  expect_eq(result.status, 0)
end

test "stores build artifacts in a directory according to Environment name" do
  test_dir "typical"

  result = run_rscons
  expect_truthy(File.exist?("build/typical/typical.exe"))
  expect_truthy(File.exist?("build/typical/o/src/one/one.c.o"))
end

test "names Environment during clone" do
  test_dir "typical"

  result = run_rscons(args: %w[-f clone_and_name.rb])
  expect_truthy(File.exist?("build/typical/typical.exe"))
  expect_truthy(File.exist?("build/typical/o/src/one/one.c.o"))
  expect_falsey(Dir.exist?("build/o"))
end

test "allows looking up environments by name" do
  test_dir "typical"

  result = run_rscons(args: %w[-f clone_with_lookup.rb])
  expect_truthy(File.exist?("build/typical/typical.exe"))
  expect_truthy(File.exist?("build/typical/o/src/one/one.c.o"))
  expect_falsey(Dir.exist?("build/first"))
end

context "colored output" do
  test "does not output in color with --color=off" do
    test_dir("simple")
    result = run_rscons(args: %w[--color=off])
    expect_eq(result.stderr, "")
    expect_not_match(result.stdout, /\e\[/)
  end

  test "displays output in color with --color=force" do
    test_dir("simple")

    result = run_rscons(args: %w[--color=force])
    expect_eq(result.stderr, "")
    expect_match(result.stdout, /\e\[/)

    File.open("simple.c", "wb") do |fh|
      fh.write("foobar")
    end
    result = run_rscons(args: %w[--color=force])
    expect_match(result.stderr, /\e\[/)
  end
end

context "Lex and Yacc builders" do
  test "builds C files using flex and bison" do
    test_dir("lex_yacc")

    result = run_rscons
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Generating lexer source from lexer.l => lexer.c},
      %r{Generating parser source from parser.y => parser.c},
    ])

    result = run_rscons
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")
  end
end

context "Command builder" do
  test "allows executing an arbitrary command" do
    test_dir('simple')

    result = run_rscons(args: %w[-f command_builder.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{BuildIt simple.exe}])
    expect_eq(nr(`./simple.exe`), "This is a simple C program\n")

    result = run_rscons(args: %w[-f command_builder.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")
  end

  test "allows redirecting standard output to a file" do
    test_dir("simple")

    result = run_rscons(args: %w[-f command_redirect.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{My Disassemble simple.txt},
    ])
    expect_match(File.read("simple.txt"), /Disassembly of section/)
  end
end

context "Directory builder" do
  test "creates the requested directory" do
    test_dir("simple")
    result = run_rscons(args: %w[-f directory.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Creating directory teh_dir}])
    expect_truthy(File.directory?("teh_dir"))
  end

  test "succeeds when the requested directory already exists" do
    test_dir("simple")
    FileUtils.mkdir("teh_dir")
    result = run_rscons(args: %w[-f directory.rb])
    expect_eq(result.stderr, "")
    line = lines(result.stdout).find {|line| line =~ /Creating directory/}
    expect(line.nil?)
    expect_truthy(File.directory?("teh_dir"))
  end

  test "fails when the target path is a file" do
    test_dir("simple")
    FileUtils.touch("teh_dir")
    result = run_rscons(args: %w[-f directory.rb])
    expect_match(result.stderr, %r{Error: `teh_dir' already exists and is not a directory})
  end
end

context "Copy builder" do
  test "copies a file to the target file name" do
    test_dir("typical")

    result = run_rscons(args: %w[-f copy.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy copy.rb => inst.exe}])

    result = run_rscons(args: %w[-f copy.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")

    expect_truthy(File.exist?("inst.exe"))
    expect_eq(File.read("inst.exe", mode: "rb"), File.read("copy.rb", mode: "rb"))

    FileUtils.rm("inst.exe")
    result = run_rscons(args: %w[-f copy.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy copy.rb => inst.exe}])
  end

  test "copies multiple files to the target directory name" do
    test_dir("typical")

    result = run_rscons(args: %w[-f copy_multiple.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy copy.rb \(\+1\) => dest}])

    result = run_rscons(args: %w[-f copy_multiple.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")

    expect_truthy(Dir.exist?("dest"))
    expect_truthy(File.exist?("dest/copy.rb"))
    expect_truthy(File.exist?("dest/copy_multiple.rb"))

    FileUtils.rm_rf("dest")
    result = run_rscons(args: %w[-f copy_multiple.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy copy.rb \(\+1\) => dest}])
  end

  test "copies a file to the target directory name" do
    test_dir("typical")

    result = run_rscons(args: %w[-f copy_directory.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy copy_directory.rb => copy}])
    expect_truthy(File.exist?("copy/copy_directory.rb"))
    expect_eq(File.read("copy/copy_directory.rb", mode: "rb"), File.read("copy_directory.rb", mode: "rb"))

    result = run_rscons(args: %w[-f copy_directory.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")
  end

  test "copies a directory to the non-existent target directory name" do
    test_dir("typical")
    result = run_rscons(args: %w[-f copy_directory.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy src => noexist/src}])
    %w[src/one/one.c src/two/two.c src/two/two.h].each do |f|
      expect_truthy(File.exist?("noexist/#{f}"))
      expect_eq(File.read("noexist/#{f}", mode: "rb"), File.read(f, mode: "rb"))
    end
  end

  test "copies a directory to the existent target directory name" do
    test_dir("typical")
    result = run_rscons(args: %w[-f copy_directory.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy src => exist/src}])
    %w[src/one/one.c src/two/two.c src/two/two.h].each do |f|
      expect_truthy(File.exist?("exist/#{f}"))
      expect_eq(File.read("exist/#{f}", mode: "rb"), File.read(f, mode: "rb"))
    end
  end
end

context "phony targets" do
  test "allows specifying a Symbol as a target name and reruns the builder if the sources or command have changed" do
    test_dir("simple")

    result = run_rscons(args: %w[-f phony_target.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.exe},
      %r{Checker simple.exe},
    ])

    result = run_rscons(args: %w[-f phony_target.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")

    FileUtils.cp("phony_target.rb", "phony_target2.rb")
    file_sub("phony_target2.rb") {|line| line.sub(/.*Program.*/, "")}
    File.open("simple.exe", "w") do |fh|
      fh.puts "Changed simple.exe"
    end
    result = run_rscons(args: %w[-f phony_target2.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Checker simple.exe},
    ])
  end

  test "supports phony targets as dependencies" do
    test_dir "typical"
    result = run_rscons(args: %w[-f phonies.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /t1.*phony2.*t2.*phony1.*t3/m)
  end
end

context "Environment#clear_targets" do
  test "clears registered targets" do
    test_dir("simple")
    result = run_rscons(args: %w[-f clear_targets.rb])
    expect_eq(result.stderr, "")
    line = lines(result.stdout).find {|line| line =~  %r{Linking}}
    expect(line.nil?)
  end
end

context "Cache management" do
  test "prints a warning when the cache is corrupt" do
    test_dir("simple")
    FileUtils.mkdir("build")
    File.open("build/.rsconscache", "w") do |fh|
      fh.puts("[1]")
    end
    result = run_rscons
    expect_match(result.stderr, /Warning.*was corrupt. Contents:/)
  end

  test "forces a build when the target file does not exist and is not in the cache" do
    test_dir("simple")
    expect_falsey(File.exist?("simple.exe"))
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_truthy(File.exist?("simple.exe"))
  end

  test "forces a build when the target file does exist but is not in the cache" do
    test_dir("simple")
    File.open("simple.exe", "wb") do |fh|
      fh.write("hi")
    end
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_truthy(File.exist?("simple.exe"))
    expect_ne(File.read("simple.exe", mode: "rb"), "hi")
  end

  test "forces a build when the target file exists and is in the cache but has changed since cached" do
    test_dir("simple")
    result = run_rscons
    expect_eq(result.stderr, "")
    File.open("simple.exe", "wb") do |fh|
      fh.write("hi")
    end
    test_dir("simple")
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_truthy(File.exist?("simple.exe"))
    expect_ne(File.read("simple.exe", mode: "rb"), "hi")
  end

  test "forces a build when the command changes" do
    test_dir("simple")

    result = run_rscons
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.exe},
    ])

    result = run_rscons(args: %w[-f cache_command_change.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Linking simple.exe},
    ])
  end

  test "forces a build when there is a new dependency" do
    test_dir("simple")

    result = run_rscons(args: %w[-f cache_new_dep1.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.exe},
    ])

    result = run_rscons(args: %w[-f cache_new_dep2.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Linking simple.exe},
    ])
  end

  test "forces a build when a dependency's checksum has changed" do
    test_dir("simple")

    result = run_rscons(args: %w[-f cache_dep_checksum_change.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy simple.c => simple.copy}])
    File.open("simple.c", "wb") do |fh|
      fh.write("hi")
    end

    result = run_rscons(args: %w[-f cache_dep_checksum_change.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{Copy simple.c => simple.copy}])
  end

  test "forces a rebuild with strict_deps=true when dependency order changes" do
    test_dir("two_sources")

    File.open("sources", "wb") do |fh|
      fh.write("one.o two.o")
    end
    result = run_rscons(args: %w[-f cache_strict_deps.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{gcc -o program.exe one.o two.o}])

    result = run_rscons(args: %w[-f cache_strict_deps.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")

    File.open("sources", "wb") do |fh|
      fh.write("two.o one.o")
    end
    result = run_rscons(args: %w[-f cache_strict_deps.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{gcc -o program.exe one.o two.o}])
  end

  test "forces a rebuild when there is a new user dependency" do
    test_dir("simple")

    File.open("foo", "wb") {|fh| fh.write("hi")}
    File.open("user_deps", "wb") {|fh| fh.write("")}
    result = run_rscons(args: %w[-f cache_user_dep.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.exe},
    ])

    File.open("user_deps", "wb") {|fh| fh.write("foo")}
    result = run_rscons(args: %w[-f cache_user_dep.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Linking simple.exe},
    ])
  end

  test "forces a rebuild when a user dependency file checksum has changed" do
    test_dir("simple")

    File.open("foo", "wb") {|fh| fh.write("hi")}
    File.open("user_deps", "wb") {|fh| fh.write("foo")}
    result = run_rscons(args: %w[-f cache_user_dep.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.exe},
    ])

    result = run_rscons(args: %w[-f cache_user_dep.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")

    File.open("foo", "wb") {|fh| fh.write("hi2")}
    result = run_rscons(args: %w[-f cache_user_dep.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{Linking simple.exe},
    ])
  end

  test "allows a VarSet to be passed in as the command parameter" do
    test_dir("simple")
    result = run_rscons(args: %w[-f cache_varset.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{TestBuilder foo},
    ])
    result = run_rscons(args: %w[-f cache_varset.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")
  end

  test "supports building multiple object files from sources with the same pathname and basename" do
    test_dir "multiple_basename"
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("foo.exe"))
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_eq(result.stdout, "")
    expect_eq(result.status, 0)
  end

  test "allows prepending and appending to PATH" do
    test_dir "simple"
    result = run_rscons(args: %w[-f pathing.rb])
    expect_eq(result.stderr, "")
    expect_match(result.stdout, /flex!/)
    expect_match(result.stdout, /foobar!/)
    expect_truthy(File.exist?("simple.o"))
  end

  test "writes the dependency file to the build root" do
    test_dir "simple"
    result = run_rscons(args: %w[-f distclean.rb])
    expect_eq(result.stderr, "")
    expect_match(result.stdout, /Compiling simple\.c/)
    expect_truthy(File.exist?("simple.o"))
    expect_falsey(File.exist?("simple.o.mf"))
    expect_truthy(File.exist?("build/o/simple.o.mf"))
  end

  context "debugging" do
    test "prints a message when the target does not exist" do
      test_dir("simple")
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Target foo\.o needs rebuilding because it does not exist on disk/)
    end

    test "prints a message when there is no cached build information for the target" do
      test_dir("simple")
      FileUtils.touch("foo.o")
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Target foo\.o needs rebuilding because there is no cached build information for it/)
    end

    test "prints a message when the target file has changed on disk" do
      test_dir("simple")
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      File.open("foo.o", "wb") {|fh| fh.puts "hi"}
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Target foo\.o needs rebuilding because it has been changed on disk since being built last/)
    end

    test "prints a message when the command has changed" do
      test_dir("simple")
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      result = run_rscons(args: %w[-f cache_debugging.rb], env: {"test" => "command_change"})
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Target foo\.o needs rebuilding because the command used to build it has changed/)
    end

    test "prints a message when strict_deps is in use and the set of dependencies does not match" do
      test_dir("simple")
      result = run_rscons(args: %w[-f cache_debugging.rb], env: {"test" => "strict_deps1"})
      expect_eq(result.stderr, "")
      result = run_rscons(args: %w[-f cache_debugging.rb], env: {"test" => "strict_deps2"})
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Target foo\.o needs rebuilding because the :strict_deps option is given and the set of dependencies does not match the previous set of dependencies/)
    end

    test "prints a message when there is a new dependency" do
      test_dir("simple")
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      result = run_rscons(args: %w[-f cache_debugging.rb], env: {"test" => "new_dep"})
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Target foo\.o needs rebuilding because there are new dependencies/)
    end

    test "prints a message when there is a new user-specified dependency" do
      test_dir("simple")
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      result = run_rscons(args: %w[-f cache_debugging.rb], env: {"test" => "new_user_dep"})
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Target foo\.o needs rebuilding because the set of user-specified dependency files has changed/)
    end

    test "prints a message when a dependency file has changed" do
      test_dir("simple")
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      f = File.read("simple.c", mode: "rb")
      f += "\n"
      File.open("simple.c", "wb") do |fh|
        fh.write(f)
      end
      result = run_rscons(args: %w[-f cache_debugging.rb])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Target foo\.o needs rebuilding because dependency file simple\.c has changed/)
    end
  end
end

context "Object builder" do
  test "allows overriding CCCMD construction variable" do
    test_dir("simple")
    result = run_rscons(args: %w[-f override_cccmd.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o simple.o -Dfoobar simple.c},
    ])
  end

  test "allows overriding DEPFILESUFFIX construction variable" do
    test_dir("simple")
    result = run_rscons(args: %w[-f override_depfilesuffix.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o simple.o -MMD -MF build/o/simple.o.deppy simple.c},
    ])
  end

  test "raises an error when given a source file with an unknown suffix" do
    test_dir("simple")
    result = run_rscons(args: %w[-f error_unknown_suffix.rb])
    expect_match(result.stderr, /Unknown input file type: "foo.xyz"/)
  end
end

context "SharedObject builder" do
  test "raises an error when given a source file with an unknown suffix" do
    test_dir("shared_library")
    result = run_rscons(args: %w[-f error_unknown_suffix.rb])
    expect_match(result.stderr, /Unknown input file type: "foo.xyz"/)
  end
end

context "Library builder" do
  test "allows overriding ARCMD construction variable" do
    test_dir("library")
    result = run_rscons(args: %w[-f override_arcmd.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [%r{ar rc lib.a build/o/one.c.o build/o/three.c.o build/o/two.c.o}])
  end

  test "allows passing object files as sources" do
    test_dir("library")
    result = run_rscons(args: %w[-f library_from_object.rb])
    expect_eq(result.stderr, "")
    expect_truthy(File.exist?("two.o"))
    verify_lines(lines(result.stdout), [%r{Building static library archive lib.a}])
  end
end

context "SharedLibrary builder" do
  test "allows explicitly specifying SHLD construction variable value" do
    test_dir("shared_library")

    result = run_rscons(args: %w[-f shared_library_set_shld.rb])
    expect_eq(result.stderr, "")
    slines = lines(result.stdout)
    if RUBY_PLATFORM =~ /mingw|msys/
      verify_lines(slines, [%r{Linking mine.dll}])
    else
      verify_lines(slines, [%r{Linking libmine.so}])
    end
  end

  test "allows passing object files as sources" do
    test_dir "shared_library"
    result = run_rscons(args: %w[-f shared_library_from_object.rb])
    expect_eq(result.stderr, "")
    expect(File.exist?("one.o"))
  end
end

context "Size builder" do
  test "generates a size file" do
    test_dir "simple"

    result = run_rscons(args: %w[-f size.rb])
    verify_lines(lines(result.stdout), [
      /Linking .*simple\.exe/,
      /Size .*simple\.exe .*simple\.size/,
    ])
    expect_truthy(File.exist?("simple.exe"))
    expect_truthy(File.exist?("simple.size"))
    expect_match(File.read("simple.size"), /text.*data/i)
  end
end

context "multi-threading" do
  test "waits for subcommands in threads for builders that support threaded commands" do
    test_dir("simple")
    start_time = Time.new
    result = run_rscons(args: %w[-f threading.rb -j 4])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{ThreadedTestBuilder a},
      %r{ThreadedTestBuilder b},
      %r{ThreadedTestBuilder c},
      %r{NonThreadedTestBuilder d},
    ])
    elapsed = Time.new - start_time
    expect(elapsed < 4)
  end

  test "allows the user to specify that a target be built after another" do
    test_dir("custom_builder")
    result = run_rscons(args: %w[-f build_after.rb -j 4])
    expect_eq(result.stderr, "")
  end

  test "allows the user to specify side-effect files produced by another builder with Builder#produces" do
    test_dir("custom_builder")
    result = run_rscons(args: %w[-f produces.rb -j 4])
    expect_eq(result.stderr, "")
    expect_truthy(File.exist?("copy_inc.h"))
  end

  test "allows the user to specify side-effect files produced by another builder with Environment#produces" do
    test_dir("custom_builder")
    result = run_rscons(args: %w[-f produces_env.rb -j 4])
    expect_eq(result.stderr, "")
    expect_truthy(File.exist?("copy_inc.h"))
  end
end

context "CLI" do
  test "shows the version number and exits with --version argument" do
    test_dir("simple")
    result = run_rscons(args: %w[--version])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /version #{Rscons::VERSION}/)
  end

  test "shows CLI help and exits with --help argument" do
    test_dir("simple")
    result = run_rscons(args: %w[--help])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /Usage:/)
  end

  test "prints an error and exits with an error status when a default Rsconscript cannot be found" do
    test_dir("simple")
    FileUtils.rm_f("Rsconscript")
    result = run_rscons
    expect_match(result.stderr, /Could not find the Rsconscript to execute/)
    expect_ne(result.status, 0)
  end

  test "prints an error and exits with an error status when the given Rsconscript cannot be read" do
    test_dir("simple")
    result = run_rscons(args: %w[-f nonexistent])
    expect_match(result.stderr, /Cannot read nonexistent/)
    expect_ne(result.status, 0)
  end

  test "outputs an error for an unknown task" do
    test_dir "simple"
    result = run_rscons(args: "unknownop")
    expect_match(result.stderr, /Task 'unknownop' not found/)
    expect_ne(result.status, 0)
  end

  test "displays usage and error message without a backtrace for an invalid CLI option" do
    test_dir "simple"
    result = run_rscons(args: %w[--xyz])
    expect_not_match(result.stderr, /Traceback/)
    expect_match(result.stderr, /invalid option.*--xyz/)
    expect_match(result.stderr, /Usage:/)
    expect_ne(result.status, 0)
  end

  test "displays usage and error message without a backtrace for an invalid CLI option to a valid subcommand" do
    test_dir "simple"
    result = run_rscons(args: %w[configure --xyz])
    expect_not_match(result.stderr, /Traceback/)
    expect_match(result.stderr, /Unknown parameter "xyz" for task configure/)
    expect_ne(result.status, 0)
  end
end

context "configure task" do
  test "does not print configuring messages when no configure block and configure task not called" do
    test_dir "configure"
    result = run_rscons(args: %w[-f no_configure_output.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_eq(result.stdout.chomp, "default")
  end

  test "raises a method not found error for configure methods called outside a configure block" do
    test_dir "configure"
    result = run_rscons(args: %w[-f scope.rb])
    expect_match(result.stderr, /NoMethodError/)
    expect_ne(result.status, 0)
  end

  test "only runs the configure operation once" do
    test_dir "configure"

    result = run_rscons(args: %w[-f configure_with_top_level_env.rb configure])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_not_match(result.stdout, %r{Configuring project.*Configuring project}m)
  end

  test "loads configure parameters before invoking configure" do
    test_dir "configure"

    result = run_rscons(args: %w[-f configure_with_top_level_env.rb configure --prefix=/yodabob])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, %r{Prefix is /yodabob})
  end

  test "does not configure for distclean operation" do
    test_dir "configure"

    result = run_rscons(args: %w[-f configure_with_top_level_env.rb distclean])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_not_match(result.stdout, %r{Configuring project})
  end

  test "does not configure for clean operation" do
    test_dir "configure"

    result = run_rscons(args: %w[-f configure_with_top_level_env.rb clean])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_not_match(result.stdout, %r{Configuring project})
  end

  test "does not configure for uninstall operation" do
    test_dir "configure"

    result = run_rscons(args: %w[-f configure_with_top_level_env.rb uninstall])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_not_match(result.stdout, %r{Configuring project})
  end

  test "automatically runs the configure task if the project is not yet configured in the given build directory" do
    test_dir "configure"

    result = run_rscons(args: %w[-f check_c_compiler.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /Checking for C compiler\.\.\./)
    expect_truthy(Dir.exist?("build/_configure"))

    result = run_rscons(args: %w[-f check_c_compiler.rb --build=bb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /Checking for C compiler\.\.\./)
    expect_truthy(Dir.exist?("bb/_configure"))
  end

  test "applies the configured settings to top-level created environments" do
    test_dir "configure"

    result = run_rscons(args: %w[-f check_c_compiler_non_default.rb -v])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /Checking for C compiler\.\.\./)
    expect_match(result.stdout, /clang.*simple\.exe/)
  end

  context "check_c_compiler" do
    {"check_c_compiler.rb" => "when no arguments are given",
     "check_c_compiler_find_first.rb" => "when arguments are given"}.each_pair do |rsconscript, desc|
      context desc do
        test "finds the first listed C compiler" do
          test_dir "configure"
          result = run_rscons(args: %W[-f #{rsconscript} configure])
          expect_eq(result.stderr, "")
          expect_eq(result.status, 0)
          expect_match(result.stdout, /Checking for C compiler\.\.\. gcc/)
        end

        test "finds the second listed C compiler" do
          test_dir "configure"
          create_exe "gcc", "exit 1"
          result = run_rscons(args: %W[-f #{rsconscript} configure])
          expect_eq(result.stderr, "")
          expect_eq(result.status, 0)
          expect_match(result.stdout, /Checking for C compiler\.\.\. clang/)
        end

        test "fails to configure when it cannot find a C compiler" do
          test_dir "configure"
          create_exe "gcc", "exit 1"
          create_exe "clang", "exit 1"
          result = run_rscons(args: %W[-f #{rsconscript} configure])
          expect_match(result.stderr, %r{Configuration failed; log file written to build/_configure/config.log})
          expect_ne(result.status, 0)
          expect_match(result.stdout, /Checking for C compiler\.\.\. not found \(checked gcc, clang\)/)
        end
      end
    end

    test "respects use flag" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_c_compiler_use.rb -v])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, %r{\bgcc .*/t1/})
      expect_not_match(result.stdout, %r{\bclang .*/t1/})
      expect_match(result.stdout, %r{\bclang .*/t2/})
      expect_not_match(result.stdout, %r{\bgcc .*/t2/})
    end

    test "successfully tests a compiler with an unknown name" do
      test_dir "configure"
      create_exe "mycompiler", %[exec gcc "$@"]
      result = run_rscons(args: %w[-f check_c_compiler_custom.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for C compiler\.\.\. mycompiler/)
    end
  end

  context "check_cxx_compiler" do
    {"check_cxx_compiler.rb" => "when no arguments are given",
     "check_cxx_compiler_find_first.rb" => "when arguments are given"}.each_pair do |rsconscript, desc|
      context desc do
        test "finds the first listed C++ compiler" do
          test_dir "configure"
          result = run_rscons(args: %W[-f #{rsconscript} configure])
          expect_eq(result.stderr, "")
          expect_eq(result.status, 0)
          expect_match(result.stdout, /Checking for C\+\+ compiler\.\.\. g\+\+/)
        end

        test "finds the second listed C++ compiler" do
          test_dir "configure"
          create_exe "g++", "exit 1"
          result = run_rscons(args: %W[-f #{rsconscript} configure])
          expect_eq(result.stderr, "")
          expect_eq(result.status, 0)
          expect_match(result.stdout, /Checking for C\+\+ compiler\.\.\. clang\+\+/)
        end

        test "fails to configure when it cannot find a C++ compiler" do
          test_dir "configure"
          create_exe "g++", "exit 1"
          create_exe "clang++", "exit 1"
          result = run_rscons(args: %W[-f #{rsconscript} configure])
          expect_match(result.stderr, %r{Configuration failed; log file written to build/_configure/config.log})
          expect_ne(result.status, 0)
          expect_match(result.stdout, /Checking for C\+\+ compiler\.\.\. not found \(checked g\+\+, clang\+\+\)/)
        end
      end
    end

    test "respects use flag" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_cxx_compiler_use.rb -v])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, %r{\bg\+\+ .*/t1/})
      expect_not_match(result.stdout, %r{\bclang\+\+ .*/t1/})
      expect_match(result.stdout, %r{\bclang\+\+ .*/t2/})
      expect_not_match(result.stdout, %r{\bg\+\+ .*/t2/})
    end

    test "successfully tests a compiler with an unknown name" do
      test_dir "configure"
      create_exe "mycompiler", %[exec clang++ "$@"]
      result = run_rscons(args: %w[-f check_cxx_compiler_custom.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for C\+\+ compiler\.\.\. mycompiler/)
    end
  end

  context "check_d_compiler" do
    {"check_d_compiler.rb" => "when no arguments are given",
     "check_d_compiler_find_first.rb" => "when arguments are given"}.each_pair do |rsconscript, desc|
      context desc do
        unless RUBY_PLATFORM =~ /mingw|msys|darwin/
          test "finds the first listed D compiler" do
            test_dir "configure"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect_eq(result.stderr, "")
            expect_eq(result.status, 0)
            expect_match(result.stdout, /Checking for D compiler\.\.\. gdc/)
          end
        end

        test "finds the second listed D compiler" do
          test_dir "configure"
          create_exe "gdc", "exit 1"
          result = run_rscons(args: %W[-f #{rsconscript} configure])
          expect_eq(result.stderr, "")
          expect_eq(result.status, 0)
          expect_match(result.stdout, /Checking for D compiler\.\.\. ldc2/)
        end

        test "fails to configure when it cannot find a D compiler" do
          test_dir "configure"
          create_exe "gdc", "exit 1"
          create_exe "ldc2", "exit 1"
          create_exe "ldc", "exit 1"
          result = run_rscons(args: %W[-f #{rsconscript} configure])
          expect_match(result.stderr, %r{Configuration failed; log file written to build/_configure/config.log})
          expect_ne(result.status, 0)
          expect_match(result.stdout, /Checking for D compiler\.\.\. not found \(checked gdc, ldc2, ldc\)/)
        end
      end
    end

    unless RUBY_PLATFORM =~ /mingw|msys|darwin/
      test "respects use flag" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_d_compiler_use.rb -v])
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_match(result.stdout, %r{\bgdc .*/t1/})
        expect_not_match(result.stdout, %r{\bldc2 .*/t1/})
        expect_match(result.stdout, %r{\bldc2 .*/t2/})
        expect_not_match(result.stdout, %r{\bgdc .*/t2/})
      end

      test "successfully tests a compiler with an unknown name that uses gdc-compatible options" do
        test_dir "configure"
        create_exe "mycompiler", %[exec gdc "$@"]
        result = run_rscons(args: %w[-f check_d_compiler_custom.rb configure])
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_match(result.stdout, /Checking for D compiler\.\.\. mycompiler/)
      end
    end

    test "successfully tests a compiler with an unknown name that uses ldc2-compatible options" do
      test_dir "configure"
      create_exe "mycompiler", %[exec ldc2 "$@"]
      result = run_rscons(args: %w[-f check_d_compiler_custom.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for D compiler\.\.\. mycompiler/)
    end
  end

  context "check_c_header" do
    test "succeeds when the requested header is found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_c_header_success.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for C header 'string\.h'... found/)
    end

    test "fails when the requested header is not found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_c_header_failure.rb configure])
      expect_match(result.stderr, /Configuration failed/)
      expect_ne(result.status, 0)
      expect_match(result.stdout, /Checking for C header 'not___found\.h'... not found/)
    end

    test "succeeds when the requested header is not found but :fail is set to false" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_c_header_no_fail.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for C header 'not___found\.h'... not found/)
    end

    test "sets the specified define when the header is found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_c_header_success_set_define.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for C header 'string\.h'... found/)
      result = run_rscons(args: %w[-f check_c_header_success_set_define.rb])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /-DHAVE_STRING_H/)
    end

    test "does not set the specified define when the header is not found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_c_header_no_fail_set_define.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for C header 'not___found\.h'... not found/)
      result = run_rscons(args: %w[-f check_c_header_no_fail_set_define.rb])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_not_match(result.stdout, /-DHAVE_/)
    end

    test "modifies CPPPATH based on check_cpppath" do
      test_dir "configure"
      FileUtils.mkdir_p("usr1")
      FileUtils.mkdir_p("usr2")
      File.open("usr2/frobulous.h", "wb") do |fh|
        fh.puts("#define FOO 42")
      end
      result = run_rscons(args: %w[-f check_c_header_cpppath.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      result = run_rscons(args: %w[-f check_c_header_cpppath.rb -v])
      expect_not_match(result.stdout, %r{-I./usr1})
      expect_match(result.stdout, %r{-I./usr2})
    end
  end

  context "check_cxx_header" do
    test "succeeds when the requested header is found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_cxx_header_success.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for C\+\+ header 'string\.h'... found/)
    end

    test "fails when the requested header is not found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_cxx_header_failure.rb configure])
      expect_match(result.stderr, /Configuration failed/)
      expect_ne(result.status, 0)
      expect_match(result.stdout, /Checking for C\+\+ header 'not___found\.h'... not found/)
    end

    test "succeeds when the requested header is not found but :fail is set to false" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_cxx_header_no_fail.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for C\+\+ header 'not___found\.h'... not found/)
    end

    test "modifies CPPPATH based on check_cpppath" do
      test_dir "configure"
      FileUtils.mkdir_p("usr1")
      FileUtils.mkdir_p("usr2")
      File.open("usr2/frobulous.h", "wb") do |fh|
        fh.puts("#define FOO 42")
      end
      result = run_rscons(args: %w[-f check_cxx_header_cpppath.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      result = run_rscons(args: %w[-f check_cxx_header_cpppath.rb -v])
      expect_not_match(result.stdout, %r{-I./usr1})
      expect_match(result.stdout, %r{-I./usr2})
    end
  end

  context "check_d_import" do
    test "succeeds when the requested import is found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_d_import_success.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for D import 'std\.stdio'... found/)
    end

    test "fails when the requested import is not found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_d_import_failure.rb configure])
      expect_match(result.stderr, /Configuration failed/)
      expect_ne(result.status, 0)
      expect_match(result.stdout, /Checking for D import 'not\.found'... not found/)
    end

    test "succeeds when the requested import is not found but :fail is set to false" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_d_import_no_fail.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for D import 'not\.found'... not found/)
    end

    test "modifies D_IMPORT_PATH based on check_d_import_path" do
      test_dir "configure"
      FileUtils.mkdir_p("usr1")
      FileUtils.mkdir_p("usr2")
      File.open("usr2/frobulous.d", "wb") do |fh|
        fh.puts("int foo = 42;")
      end
      result = run_rscons(args: %w[-f check_d_import_d_import_path.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      result = run_rscons(args: %w[-f check_d_import_d_import_path.rb -v])
      expect_not_match(result.stdout, %r{-I./usr1})
      expect_match(result.stdout, %r{-I./usr2})
    end
  end

  context "check_lib" do
    test "succeeds when the requested library is found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_lib_success.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for library 'm'... found/)
    end

    test "fails when the requested library is not found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_lib_failure.rb configure])
      expect_match(result.stderr, /Configuration failed/)
      expect_ne(result.status, 0)
      expect_match(result.stdout, /Checking for library 'mfoofoo'... not found/)
    end

    test "succeeds when the requested library is not found but :fail is set to false" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_lib_no_fail.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for library 'mfoofoo'... not found/)
    end

    test "links against the checked library by default" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_lib_success.rb])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for library 'm'... found/)
      expect_match(result.stdout, /gcc.*-lm/)
    end

    test "does not link against the checked library by default if :use is specified" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_lib_use.rb])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for library 'm'... found/)
      expect_not_match(result.stdout, /gcc.*test1.*-lm/)
      expect_match(result.stdout, /gcc.*test2.*-lm/)
    end

    test "does not link against the checked library if :use is set to false" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_lib_use_false.rb])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for library 'm'... found/)
      expect_not_match(result.stdout, /-lm/)
    end

    test "finds the requested library with only ldc compiler" do
      test_dir "configure"
      create_exe "gcc", "exit 1"
      create_exe "clang", "exit 1"
      create_exe "gcc++", "exit 1"
      create_exe "clang++", "exit 1"
      result = run_rscons(args: %w[-f check_lib_with_ldc.rb])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for library 'z'... found/)
    end

    test "modifies LIBPATH based on check_libpath" do
      test_dir "configure"
      FileUtils.mkdir_p("usr1")
      FileUtils.mkdir_p("usr2")
      result = run_rscons(args: %w[-f check_lib_libpath1.rb])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      result = run_rscons(args: %w[-f check_lib_libpath2.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      result = run_rscons(args: %w[-f check_lib_libpath2.rb])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, %r{-L\./usr2})
      expect_not_match(result.stdout, %r{-L\./usr1})
    end
  end

  context "check_program" do
    test "succeeds when the requested program is found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_program_success.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for program 'find'... .*find/)
    end

    context "with non-existent PATH entries" do
      test "succeeds when the requested program is found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_program_success.rb configure], path: "/foo/bar")
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_match(result.stdout, /Checking for program 'find'... .*find/)
      end
    end

    test "fails when the requested program is not found" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_program_failure.rb configure])
      expect_match(result.stderr, /Configuration failed/)
      expect_ne(result.status, 0)
      expect_match(result.stdout, /Checking for program 'program-that-is-not-found'... not found/)
    end

    test "succeeds when the requested program is not found but :fail is set to false" do
      test_dir "configure"
      result = run_rscons(args: %w[-f check_program_no_fail.rb configure])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      expect_match(result.stdout, /Checking for program 'program-that-is-not-found'... not found/)
    end
  end

  context "check_cfg" do
    context "when passed a package" do
      test "stores flags and uses them during a build" do
        test_dir "configure"
        create_exe "pkg-config", "echo '-DMYPACKAGE'"
        result = run_rscons(args: %w[-f check_cfg_package.rb configure])
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_match(result.stdout, /Checking for package 'mypackage'\.\.\. found/)
        result = run_rscons(args: %w[-f check_cfg_package.rb])
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_match(result.stdout, /gcc.*-o.*\.o.*-DMYPACKAGE/)
      end

      test "fails when the configure program given does not exist" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_cfg.rb configure])
        expect_match(result.stderr, /Configuration failed/)
        expect_ne(result.status, 0)
        expect_match(result.stdout, /Checking 'my-config'\.\.\. not found/)
      end

      test "does not use the flags found by default if :use is specified" do
        test_dir "configure"
        create_exe "pkg-config", "echo '-DMYPACKAGE'"
        result = run_rscons(args: %w[-f check_cfg_use.rb configure])
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_match(result.stdout, /Checking for package 'mypackage'\.\.\. found/)
        result = run_rscons(args: %w[-f check_cfg_use.rb])
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_not_match(result.stdout, /gcc.*-o.*myconfigtest1.*-DMYPACKAGE/)
        expect_match(result.stdout, /gcc.*-o.*myconfigtest2.*-DMYPACKAGE/)
      end

      test "indicates that pkg-config command cannot be found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_cfg_no_pkg_config.rb configure])
        expect_match(result.stderr, /Error: executable 'pkg-config' not found/)
        expect_ne(result.status, 0)
      end
    end

    context "when passed a program" do
      test "stores flags and uses them during a build" do
        test_dir "configure"
        create_exe "my-config", "echo '-DMYCONFIG -lm'"
        result = run_rscons(args: %w[-f check_cfg.rb configure])
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_match(result.stdout, /Checking 'my-config'\.\.\. found/)
        result = run_rscons(args: %w[-f check_cfg.rb])
        expect_eq(result.stderr, "")
        expect_eq(result.status, 0)
        expect_match(result.stdout, /gcc.*-o.*\.o.*-DMYCONFIG/)
        expect_match(result.stdout, /gcc.*-o myconfigtest.*-lm/)
      end
    end
  end

  context "custom_check" do
    context "when running a test command" do
      context "when executing the command fails" do
        context "when failures are fatal" do
          test "fails configuration with the correct error message" do
            test_dir "configure"
            create_exe "grep", "exit 4"
            result = run_rscons(args: %w[-f custom_config_check.rb configure])
            expect_match(result.stderr, /Configuration failed/)
            expect_match(result.stdout, /Checking 'grep' version\.\.\. error executing grep/)
            expect_ne(result.status, 0)
          end
        end

        context "when the custom logic indicates a failure" do
          test "fails configuration with the correct error message" do
            test_dir "configure"
            create_exe "grep", "echo 'grep (GNU grep) 1.1'"
            result = run_rscons(args: %w[-f custom_config_check.rb configure])
            expect_match(result.stderr, /Configuration failed/)
            expect_match(result.stdout, /Checking 'grep' version\.\.\. too old!/)
            expect_ne(result.status, 0)
          end
        end
      end

      context "when failures are not fatal" do
        context "when the custom logic indicates a failure" do
          test "displays the correct message and does not fail configuration" do
            test_dir "configure"
            create_exe "grep", "echo 'grep (GNU grep) 2.1'"
            result = run_rscons(args: %w[-f custom_config_check.rb configure])
            expect_eq(result.stderr, "")
            expect_match(result.stdout, /Checking 'grep' version\.\.\. we'll work with it but you should upgrade/)
            expect_eq(result.status, 0)
            result = run_rscons(args: %w[-f custom_config_check.rb])
            expect_eq(result.stderr, "")
            expect_match(result.stdout, /GREP_WORKAROUND/)
            expect_eq(result.status, 0)
          end
        end
      end

      context "when the custom logic indicates success" do
        test "passes configuration with the correct message" do
          test_dir "configure"
          create_exe "grep", "echo 'grep (GNU grep) 3.0'"
          result = run_rscons(args: %w[-f custom_config_check.rb configure])
          expect_eq(result.stderr, "")
          expect_match(result.stdout, /Checking 'grep' version\.\.\. good!/)
          expect_eq(result.status, 0)
          result = run_rscons(args: %w[-f custom_config_check.rb])
          expect_eq(result.stderr, "")
          expect_match(result.stdout, /GREP_FULL/)
          expect_eq(result.status, 0)
        end
      end

      test "allows passing standard input data to the executed command" do
        test_dir "configure"
        result = run_rscons(args: %w[-f custom_config_check.rb configure])
        expect_eq(result.stderr, "")
        expect_match(result.stdout, /Checking sed -E flag\.\.\. good/)
        expect_eq(result.status, 0)
      end
    end
  end

  context "on_fail option" do
    test "prints on_fail messages and calls on_fail procs on failure" do
      test_dir "configure"
      result = run_rscons(args: %w[-f on_fail.rb configure])
      expect_ne(result.status, 0)
      expect_match(result.stdout, /Install the foo123 package/)
      expect_match(result.stdout, /Install the foo123cxx package/)
    end
  end

  test "does everything" do
    test_dir "configure"
    create_exe "pkg-config", "echo '-DMYPACKAGE'"
    result = run_rscons(args: %w[-f everything.rb --build=bb configure --prefix=/my/prefix])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /Configuring configure test\.\.\./)
    expect_match(result.stdout, %r{Setting prefix\.\.\. /my/prefix})
    expect_match(result.stdout, /Checking for C compiler\.\.\. gcc/)
    expect_match(result.stdout, /Checking for C\+\+ compiler\.\.\. g\+\+/)
    expect_match(result.stdout, /Checking for D compiler\.\.\. (gdc|ldc2)/)
    expect_match(result.stdout, /Checking for package 'mypackage'\.\.\. found/)
    expect_match(result.stdout, /Checking for C header 'stdio.h'\.\.\. found/)
    expect_match(result.stdout, /Checking for C\+\+ header 'iostream'\.\.\. found/)
    expect_match(result.stdout, /Checking for D import 'std.stdio'\.\.\. found/)
    expect_match(result.stdout, /Checking for library 'm'\.\.\. found/)
    expect_match(result.stdout, /Checking for program 'ls'\.\.\. .*ls/)
    expect_falsey(Dir.exist?("build"))
    expect_truthy(Dir.exist?("bb/_configure"))
  end

  test "aggregates multiple set_define's" do
    test_dir "configure"
    result = run_rscons(args: %w[-f multiple_set_define.rb configure])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    result = run_rscons(args: %w[-f multiple_set_define.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /gcc.*-o.*\.o.*-DHAVE_MATH_H\s.*-DHAVE_STDIO_H/)
  end

  test "exits with an error if the project is not configured and a build is requested and autoconf is false" do
    test_dir "configure"
    result = run_rscons(args: %w[-f autoconf_false.rb])
    expect_match(result.stderr, /Project must be configured before creating an Environment/)
    expect_ne(result.status, 0)
  end

  test "exits with an error code and message if configuration fails during autoconf" do
    test_dir "configure"
    result = run_rscons(args: %w[-f autoconf_fail.rb])
    expect_match(result.stdout, /Checking for C compiler\.\.\. not found/)
    expect_ne(result.status, 0)
    expect_not_match(result.stderr, /from\s/)
    expect_match(lines(result.stderr).last, /Configuration failed/)
  end

  test "does not rebuild after building with auto-configuration" do
    test_dir "configure"
    result = run_rscons(args: %w[-f autoconf_rebuild.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("simple.exe"))
    result = run_rscons(args: %w[-f autoconf_rebuild.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_eq(result.stdout, "")
  end
end

context "distclean" do
  test "removes built files and the build directory" do
    test_dir "simple"
    result = run_rscons(args: %w[-f distclean.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("simple.o"))
    expect_truthy(File.exist?("build"))
    result = run_rscons(args: %w[-f distclean.rb distclean])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_falsey(File.exist?("simple.o"))
    expect_falsey(File.exist?("build"))
  end
end

context "verbose option" do
  test "does not echo commands when verbose options not given" do
    test_dir('simple')
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_match(result.stdout, /Compiling.*simple\.c/)
  end

  test "echoes commands by default with -v" do
    test_dir('simple')
    result = run_rscons(args: %w[-v])
    expect_eq(result.stderr, "")
    expect_match(result.stdout, /gcc.*-o.*simple/)
  end

  test "echoes commands by default with --verbose" do
    test_dir('simple')
    result = run_rscons(args: %w[--verbose])
    expect_eq(result.stderr, "")
    expect_match(result.stdout, /gcc.*-o.*simple/)
  end
end

context "direct mode" do
  test "allows calling Program builder in direct mode and passes all sources to the C compiler" do
    test_dir("direct")

    result = run_rscons(args: %w[-f c_program.rb])
    expect_eq(result.stderr, "")
    expect_match(result.stdout, %r{Compiling/Linking})
    expect_truthy(File.exist?("test.exe"))
    expect_match(`./test.exe`, /three/)

    result = run_rscons(args: %w[-f c_program.rb])
    expect_eq(result.stdout, "")

    three_h = File.read("three.h", mode: "rb")
    File.open("three.h", "wb") do |fh|
      fh.write(three_h)
      fh.puts("#define FOO 42")
    end
    result = run_rscons(args: %w[-f c_program.rb])
    expect_match(result.stdout, %r{Compiling/Linking})
  end

  test "allows calling SharedLibrary builder in direct mode and passes all sources to the C compiler" do
    test_dir("direct")

    result = run_rscons(args: %w[-f c_shared_library.rb])
    expect_eq(result.stderr, "")
    expect_match(result.stdout, %r{Compiling/Linking})
    expect_truthy(File.exist?("test.exe"))
    ld_library_path_prefix = (RUBY_PLATFORM =~ /mingw|msys/ ? "" : "LD_LIBRARY_PATH=. ")
    expect_match(`#{ld_library_path_prefix}./test.exe`, /three/)

    result = run_rscons(args: %w[-f c_shared_library.rb])
    expect_eq(result.stdout, "")

    three_h = File.read("three.h", mode: "rb")
    File.open("three.h", "wb") do |fh|
      fh.write(three_h)
      fh.puts("#define FOO 42")
    end
    result = run_rscons(args: %w[-f c_shared_library.rb])
    expect_match(result.stdout, %r{Compiling/Linking})
  end
end

context "install task" do
  test "invokes the configure task if the project is not yet configured" do
    test_dir "typical"

    result = run_rscons(args: %w[-f install.rb install])
    expect_match(result.stdout, /Configuring install_test/)
  end

  test "invokes a build dependency" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")
      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Compiling/)
      expect_match(result.stdout, /Linking/)
    end
  end

  test "installs the requested directories and files" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Creating directory/)
      expect_match(result.stdout, /Install install.rb =>/)
      expect_match(result.stdout, /Install src =>/)
      expect_match_array(Dir.entries(prefix), %w[. .. bin src share mult])
      expect_truthy(File.directory?("#{prefix}/bin"))
      expect_truthy(File.directory?("#{prefix}/src"))
      expect_truthy(File.directory?("#{prefix}/share"))
      expect_truthy(File.exist?("#{prefix}/bin/program.exe"))
      expect_truthy(File.exist?("#{prefix}/src/one/one.c"))
      expect_truthy(File.exist?("#{prefix}/share/proj/install.rb"))
      expect_truthy(File.exist?("#{prefix}/mult/install.rb"))
      expect_truthy(File.exist?("#{prefix}/mult/copy.rb"))

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")
      expect_eq(result.stdout, "")
    end
  end

  test "does not install when only a build is performed" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb])
      expect_eq(result.stderr, "")
      expect_not_match(result.stdout, /Install/)
      expect_match_array(Dir.entries(prefix), %w[. ..])

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, /Install/)
    end
  end
end

context "uninstall task" do
  test "removes installed files but not built files" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")
      expect_truthy(File.exist?("#{prefix}/bin/program.exe"))
      expect_truthy(File.exist?("build/o/src/one/one.c.o"))

      result = run_rscons(args: %w[-f install.rb uninstall])
      expect_eq(result.stderr, "")
      expect_not_match(result.stdout, /Removing/)
      expect_falsey(File.exist?("#{prefix}/bin/program.exe"))
      expect_truthy(File.exist?("build/o/src/one/one.c.o"))
      expect_match_array(Dir.entries(prefix), %w[. ..])
    end
  end

  test "prints removed files and directories when running verbosely" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb -v uninstall])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, %r{Removing #{prefix}/bin/program.exe})
      expect_falsey(File.exist?("#{prefix}/bin/program.exe"))
      expect_match_array(Dir.entries(prefix), %w[. ..])
    end
  end

  test "removes cache entries when uninstalling" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb -v uninstall])
      expect_eq(result.stderr, "")
      expect_match(result.stdout, %r{Removing #{prefix}/bin/program.exe})
      expect_falsey(File.exist?("#{prefix}/bin/program.exe"))
      expect_match_array(Dir.entries(prefix), %w[. ..])

      FileUtils.mkdir_p("#{prefix}/bin")
      File.open("#{prefix}/bin/program.exe", "w") {|fh| fh.write("hi")}
      result = run_rscons(args: %w[-f install.rb -v uninstall])
      expect_eq(result.stderr, "")
      expect_not_match(result.stdout, /Removing/)
    end
  end
end

context "build progress" do
  test "does not include install targets in build progress when not doing an install" do
    test_dir "typical"

    result = run_rscons(args: %w[-f install.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{\[1/3\] Compiling},
      %r{\[2/3\] Compiling},
      %r{\[3/3\] Linking},
    ])
  end

  test "counts install task targets separately from build task targets" do
    test_dir "typical"

    Dir.mktmpdir do |prefix|
      result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
      expect_eq(result.stderr, "")

      result = run_rscons(args: %w[-f install.rb install])
      expect_eq(result.stderr, "")
      verify_lines(lines(result.stdout), [
        %r{\[1/3\] Compiling},
        %r{\[2/3\] Compiling},
        %r{\[\d/6\] Install},
      ])
    end
  end

  test "separates build steps from each environment when showing build progress" do
    test_dir "typical"

    result = run_rscons(args: %w[-f multiple_environments.rb])
    expect_eq(result.stderr, "")
    verify_lines(lines(result.stdout), [
      %r{\[1/3\] Compiling},
      %r{\[2/3\] Compiling},
      %r{\[3/3\] Linking},
      %r{\[1/3\] Compiling},
      %r{\[2/3\] Compiling},
      %r{\[3/3\] Linking},
    ])
  end
end

context "with subsidiary scripts" do
  context "with a script specified" do
    test "executes the subsidiary script from configure block" do
      test_dir "subsidiary"

      result = run_rscons(args: %w[configure])
      expect_eq(result.stderr, "")
      verify_lines(lines(result.stdout), [
        %r{Entering directory '.*/sub'},
        %r{sub Rsconscript configure},
        %r{Leaving directory '.*/sub'},
        %r{Entering directory '.*/sub'},
        %r{sub Rsconscript build},
        %r{Leaving directory '.*/sub'},
        %r{Entering directory '.*/sub'},
        %r{sub Rsconscript2 configure},
        %r{Leaving directory '.*/sub'},
        %r{top configure},
      ])
    end

    test "executes the subsidiary script from build block" do
      test_dir "subsidiary"

      result = run_rscons(args: %w[configure])
      expect_eq(result.stderr, "")
      result = run_rscons
      expect_eq(result.stderr, "")
      verify_lines(lines(result.stdout), [
        %r{sub Rsconscript2 build},
        %r{top build},
      ])
    end
  end

  context "with a directory specified" do
    test "executes the subsidiary script from configure block" do
      test_dir "subsidiary"

      result = run_rscons(args: %w[-f Rsconscript_dir configure])
      expect_eq(result.stderr, "")
      verify_lines(lines(result.stdout), [
        %r{Entering directory '.*/sub'},
        %r{sub Rsconscript configure},
        %r{Leaving directory '.*/sub'},
        %r{Entering directory '.*/sub'},
        %r{sub Rsconscript build},
        %r{Leaving directory '.*/sub'},
        %r{Entering directory '.*/sub'},
        %r{sub Rsconscript2 configure},
        %r{Leaving directory '.*/sub'},
        %r{top configure},
      ])
    end

    test "executes the subsidiary script from build block" do
      test_dir "subsidiary"

      result = run_rscons(args: %w[-f Rsconscript_dir configure])
      expect_eq(result.stderr, "")
      result = run_rscons(args: %w[-f Rsconscript_dir])
      expect_eq(result.stderr, "")
      verify_lines(lines(result.stdout), [
        %r{sub Rsconscript2 build},
        %r{top build},
      ])
    end
  end

  context "with a rscons binary in the subsidiary script directory" do
    test "executes rscons from the subsidiary script directory" do
      test_dir "subsidiary"

      File.binwrite("sub/rscons", <<EOF)
#!/usr/bin/env ruby
puts "sub rscons"
EOF
      FileUtils.chmod(0755, "sub/rscons")
      result = run_rscons(args: %w[configure])
      expect_eq(result.stderr, "")
      verify_lines(lines(result.stdout), [
        %r{Entering directory '.*/sub'},
        %r{sub rscons},
        %r{Leaving directory '.*/sub'},
        %r{Entering directory '.*/sub'},
        %r{sub rscons},
        %r{Leaving directory '.*/sub'},
        %r{Entering directory '.*/sub'},
        %r{sub rscons},
        %r{Leaving directory '.*/sub'},
        %r{top configure},
      ])
    end
  end

  test "does not print entering/leaving directory messages when the subsidiary script is in the same directory" do
    test_dir "subsidiary"

    result = run_rscons(args: %w[-f Rsconscript_samedir configure])
    expect_eq(result.stderr, "")
    result = run_rscons(args: %w[-f Rsconscript_samedir])
    expect_eq(result.stderr, "")
    expect_not_match(result.stdout, %r{(Entering|Leaving) directory})
    verify_lines(lines(result.stdout), [
      %r{second build},
      %r{top build},
    ])
  end

  test "terminates execution when a subsidiary script fails" do
    test_dir "subsidiary"

    result = run_rscons(args: %w[-f Rsconscript_fail configure])
    expect_ne(result.stderr, "")
    expect_ne(result.status, 0)
    expect_not_match(result.stdout, /top configure/)
  end

  test "does not pass RSCONS_BUILD_DIR to subsidiary scripts" do
    test_dir "subsidiary"
    result = run_rscons(args: %w[configure], env: {"RSCONS_BUILD_DIR" => "buildit"})
    expect_eq(result.stderr, "")
    expect_falsey(Dir.exist?("build"))
    expect_truthy(Dir.exist?("buildit"))
    expect_truthy(Dir.exist?("sub/build"))
    expect_falsey(Dir.exist?("sub/buildit"))
  end
end

context "sh method" do
  test "executes the command given" do
    test_dir "typical"
    result = run_rscons(args: %w[-f sh.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    verify_lines(lines(result.stdout), [
      "hi  there",
      "1 2",
    ])
  end

  test "changes directory to execute the requested command" do
    test_dir "typical"
    result = run_rscons(args: %w[-f sh_chdir.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, %r{/src$})
  end

  test "prints the command when executing verbosely" do
    test_dir "typical"
    result = run_rscons(args: %w[-f sh.rb -v])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    verify_lines(lines(result.stdout), [
      %r{echo 'hi  there'},
      "hi  there",
      %r{echo  1  2},
      "1 2",
    ])
  end

  test "terminates execution on failure" do
    test_dir "typical"
    result = run_rscons(args: %w[-f sh_fail.rb])
    expect_match(result.stderr, /sh_fail\.rb:2:.*foobar42/)
    expect_ne(result.status, 0)
    expect_not_match(result.stdout, /continued/)
  end

  test "continues execution on failure when :continue option is set" do
    test_dir "typical"
    result = run_rscons(args: %w[-f sh_fail_continue.rb])
    expect_match(result.stderr, /sh_fail_continue\.rb:2:.*foobar42/)
    expect_eq(result.status, 0)
    expect_match(result.stdout, /continued/)
  end
end

context "FileUtils methods" do
  test "defines FileUtils methods to be available in the build script" do
    test_dir "typical"
    result = run_rscons(args: %w[-f fileutils_methods.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(Dir.exist?("foobar"))
    expect_falsey(Dir.exist?("foo"))
    expect_truthy(File.exist?("foobar/baz/b.txt"))
  end
end

test "executes the requested tasks in the requested order" do
  test_dir "tasks"
  result = run_rscons(args: %w[-f tasks.rb configure])
  result = run_rscons(args: %w[-f tasks.rb one three])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_eq(result.stdout, "one\nthree\n")
  result = run_rscons(args: %w[-f tasks.rb three one])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_eq(result.stdout, "three\none\n")
end

test "executes the task's dependencies before the requested task" do
  test_dir "tasks"
  result = run_rscons(args: %w[-f tasks.rb configure])
  result = run_rscons(args: %w[-f tasks.rb two])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_eq(result.stdout, "one\nthree\ntwo\n")
end

test "does not execute a task more than once" do
  test_dir "tasks"
  result = run_rscons(args: %w[-f tasks.rb configure])
  result = run_rscons(args: %w[-f tasks.rb one two three])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_eq(result.stdout, "one\nthree\ntwo\n")
end

test "passes task arguments" do
  test_dir "tasks"
  result = run_rscons(args: %w[-f tasks.rb configure])
  result = run_rscons(args: %w[-f tasks.rb four])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_eq(result.stdout, %[four\nmyparam:"defaultvalue"\nmyp2:nil\n])
  result = run_rscons(args: %w[-f tasks.rb four --myparam=cli-value --myp2 one])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_eq(result.stdout, %[four\nmyparam:"cli-value"\nmyp2:true\none\n])
end

test "allows accessing task arguments via Task#[]" do
  test_dir "tasks"
  result = run_rscons(args: %w[-f tasks.rb configure])
  result = run_rscons(args: %w[-f tasks.rb five])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_match(result.stdout, /four myparam value is defaultvalue/)
  result = run_rscons(args: %w[-f tasks.rb four --myparam=v42 five])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_match(result.stdout, /four myparam value is v42/)
end

test "exits with an error when attempting to get a nonexistent parameter value" do
  test_dir "tasks"
  result = run_rscons(args: %w[-f tasks.rb configure])
  result = run_rscons(args: %w[-f tasks.rb six])
  expect_match(result.stderr, /Could not find parameter 'nope'/)
  expect_ne(result.status, 0)
end

context "with -T flag" do
  test "displays tasks and their parameters" do
    test_dir "tasks"
    result = run_rscons(args: %w[-f tasks.rb -T])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    verify_lines(lines(result.stdout), [
      "Tasks:",
      /\bthree\b\s+Task three/,
      /\bfour\b\s+Task four/,
      /--myparam=MYPARAM\s+My special parameter/,
      /--myp2\s+My parameter 2/,
    ])
    expect_not_match(result.stdout, /^\s*one\b/)
    expect_not_match(result.stdout, /^\s*two\b/)
  end

  context "with -A flag" do
    test "displays all tasks and their parameters" do
      test_dir "tasks"
      result = run_rscons(args: %w[-f tasks.rb -AT])
      expect_eq(result.stderr, "")
      expect_eq(result.status, 0)
      verify_lines(lines(result.stdout), [
        "Tasks:",
        /\bone\b/,
        /\btwo\b/,
        /\bthree\b\s+Task three/,
        /\bfour\b\s+Task four/,
        /--myparam=MYPARAM\s+My special parameter/,
        /--myp2\s+My parameter 2/,
        /\bfive\b/,
        /\bsix\b/,
      ])
    end
  end
end

context "download script method" do
  test "downloads the specified file unless it already exists with the expected checksum" do
    test_dir "typical"
    result = run_rscons(args: %w[-f download.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("rscons-2.3.0"))
  end

  test "downloads the specified file if no checksum is given" do
    test_dir "typical"
    result = run_rscons(args: %w[-f download.rb nochecksum])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("rscons-2.3.0"))
    expect(File.binread("rscons-2.3.0").size > 100)
  end

  test "exits with an error if the downloaded file checksum does not match the given checksum" do
    test_dir "typical"
    result = run_rscons(args: %w[-f download.rb badchecksum])
    expect_match(result.stderr, /Unexpected checksum on rscons-2.3.0/)
    expect_ne(result.status, 0)
  end

  test "exits with an error if the redirect limit is reached" do
    test_dir "typical"
    result = run_rscons(args: %w[-f download.rb redirectlimit])
    expect_match(result.stderr, /Redirect limit reached when downloading rscons-2.3.0/)
    expect_ne(result.status, 0)
  end

  test "exits with an error if the download results in an error" do
    test_dir "typical"
    result = run_rscons(args: %w[-f download.rb badurl])
    expect_match(result.stderr, /Error downloading rscons-2.3.0/)
    expect_ne(result.status, 0)
  end

  test "exits with an error if the download results in a socket error" do
    test_dir "typical"
    result = run_rscons(args: %w[-f download.rb badhost])
    expect_match(result.stderr, /Error downloading foo: .*ksfjlias/)
    expect_ne(result.status, 0)
  end
end

context "configure task parameters" do
  test "allows access to configure task parameters from another task" do
    test_dir "tasks"

    result = run_rscons(args: %w[-f configure_params.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /xyz: xyz/)
    expect_match(result.stdout, /flag: nil/)

    result = run_rscons(args: %w[-f configure_params.rb configure --with-xyz=foo --flag default])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /xyz: foo/)
    expect_match(result.stdout, /flag: true/)
  end

  test "stores configure task parameters in the cache for subsequent invocations" do
    test_dir "tasks"

    result = run_rscons(args: %w[-f configure_params.rb configure --with-xyz=foo --flag default])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /xyz: foo/)
    expect_match(result.stdout, /flag: true/)

    result = run_rscons(args: %w[-f configure_params.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, /xyz: foo/)
    expect_match(result.stdout, /flag: true/)
  end
end

context "variants" do
  test "appends variant names to environment names to form build directories" do
    test_dir "variants"
    result = run_rscons
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("build/prog-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-release/prog.exe"))
  end

  test "allows querying active variants and changing behavior" do
    test_dir "variants"
    result = run_rscons(args: %w[-v])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("build/prog-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-release/prog.exe"))
    expect_match(result.stdout, %r{gcc .*-o.*build/prog-debug/.*-DDEBUG})
    expect_match(result.stdout, %r{gcc .*-o.*build/prog-release/.*-DNDEBUG})
  end

  test "allows specifying a nil key for a variant" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f nil_key.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("build/prog-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog/prog.exe"))
    expect_match(result.stdout, %r{gcc .*-o.*build/prog-debug/.*-DDEBUG})
    expect_match(result.stdout, %r{gcc .*-o.*build/prog/.*-DNDEBUG})
  end

  test "allows multiple variant groups" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f multiple_groups.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("build/prog-kde-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-kde-release/prog.exe"))
    expect_truthy(File.exist?("build/prog-gnome-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-gnome-release/prog.exe"))
    expect_match(result.stdout, %r{gcc .*-o.*build/prog-kde-debug/.*-DKDE.*-DDEBUG})
    expect_match(result.stdout, %r{gcc .*-o.*build/prog-kde-release/.*-DKDE.*-DNDEBUG})
    expect_match(result.stdout, %r{gcc .*-o.*build/prog-gnome-debug/.*-DGNOME.*-DDEBUG})
    expect_match(result.stdout, %r{gcc .*-o.*build/prog-gnome-release/.*-DGNOME.*-DNDEBUG})
  end

  test "raises an error when with_variants is called within another with_variants block" do
    test_dir "variants"
    result = run_rscons(args: %w[-f error_nested_with_variants.rb])
    expect_match(result.stderr, %r{with_variants cannot be called within another with_variants block})
    expect_ne(result.status, 0)
  end

  test "raises an error when with_variants is called with no variants defined" do
    test_dir "variants"
    result = run_rscons(args: %w[-f error_with_variants_without_variants.rb])
    expect_match(result.stderr, %r{with_variants cannot be called with no variants defined})
    expect_ne(result.status, 0)
  end

  test "allows specifying the exact enabled variants on the command line 1" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f multiple_groups.rb -e kde,debug])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("build/prog-kde-debug/prog.exe"))
    expect_falsey(File.exist?("build/prog-kde-release/prog.exe"))
    expect_falsey(File.exist?("build/prog-gnome-debug/prog.exe"))
    expect_falsey(File.exist?("build/prog-gnome-release/prog.exe"))
  end

  test "allows specifying the exact enabled variants on the command line 2" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f multiple_groups.rb -e kde,gnome,release])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_falsey(File.exist?("build/prog-kde-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-kde-release/prog.exe"))
    expect_falsey(File.exist?("build/prog-gnome-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-gnome-release/prog.exe"))
  end

  test "allows disabling a single variant on the command line" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f multiple_groups.rb --variants=-kde])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_falsey(File.exist?("build/prog-kde-debug/prog.exe"))
    expect_falsey(File.exist?("build/prog-kde-release/prog.exe"))
    expect_truthy(File.exist?("build/prog-gnome-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-gnome-release/prog.exe"))
  end

  test "allows turning off variants by default" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f default.rb])
    expect_falsey(File.exist?("build/prog-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-release/prog.exe"))
  end

  test "allows turning on an off-by-default-variant from the command line" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f default.rb -e +debug])
    expect_truthy(File.exist?("build/prog-debug/prog.exe"))
    expect_truthy(File.exist?("build/prog-release/prog.exe"))
  end

  test "allows only turning on an off-by-default-variant from the command line" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f default.rb -e debug])
    expect_truthy(File.exist?("build/prog-debug/prog.exe"))
    expect_falsey(File.exist?("build/prog-release/prog.exe"))
  end

  test "exits with an error if no variant in a variant group is activated" do
    test_dir "variants"
    result = run_rscons(args: %w[-v -f multiple_groups.rb --variants=kde])
    expect_match(result.stderr, %r{No variants enabled for variant group})
    expect_ne(result.status, 0)
  end

  test "allows querying if a variant is enabled" do
    test_dir "variants"

    result = run_rscons(args: %w[-f variant_enabled.rb configure])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, %r{one enabled})
    expect_not_match(result.stdout, %r{two enabled})
    expect_not_match(result.stdout, %r{three enabled})

    result = run_rscons(args: %w[-f variant_enabled.rb --variants=+two configure])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_match(result.stdout, %r{one enabled})
    expect_match(result.stdout, %r{two enabled})
    expect_not_match(result.stdout, %r{three enabled})

    result = run_rscons(args: %w[-f variant_enabled.rb --variants=two configure])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_not_match(result.stdout, %r{one enabled})
    expect_match(result.stdout, %r{two enabled})
    expect_not_match(result.stdout, %r{three enabled})
  end

  test "shows available variants with -T" do
    test_dir "variants"

    result = run_rscons(args: %w[-f multiple_groups.rb -T])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    verify_lines(lines(result.stdout), [
      "Variant group 'desktop-environment':",
      "  kde (enabled)",
      "  gnome (enabled)",
      "Variant group 'debug':",
      "  debug (enabled)",
      "  release (enabled)",
    ])

    result = run_rscons(args: %w[-f multiple_groups.rb -e gnome,release configure])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    result = run_rscons(args: %w[-f multiple_groups.rb -T])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    verify_lines(lines(result.stdout), [
      "Variant group 'desktop-environment':",
      "  kde",
      "  gnome (enabled)",
      "Variant group 'debug':",
      "  debug",
      "  release (enabled)",
    ])
  end

  test "raises an error when an unnamed environment is created with multiple active variants" do
    test_dir "variants"
    result = run_rscons(args: %w[-f error_unnamed_environment.rb])
    expect_match(result.stderr, /Error: an Environment with active variants must be given a name/)
    expect_ne(result.status, 0)
  end
end

context "build_dir method" do
  test "returns the top-level build directory path 1" do
    test_dir "typical"
    result = run_rscons(args: %w[-f build_dir.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("build/a.file"))
  end

  test "returns the top-level build directory path 2" do
    test_dir "typical"
    result = run_rscons(args: %w[-f build_dir.rb -b bb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("bb/a.file"))
  end
end

if RUBY_PLATFORM =~ /linux/
  test "allows writing a binary to an environment's build directory with the same name as a top-level source folder" do
    test_dir "typical"
    result = run_rscons(args: %w[-f binary_matching_folder.rb])
    expect_eq(result.stderr, "")
    expect_eq(result.status, 0)
    expect_truthy(File.exist?("build/src/src"))
  end
end

test "supports building LLVM assembly files with the Program builder" do
  test_dir "llvm"
  result = run_rscons
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_truthy(File.exist?("llvmtest.exe"))
  expect_match(`./llvmtest.exe`, /hello world/)
end

test "supports building LLVM assembly files with the Program builder in direct mode" do
  test_dir "llvm"
  result = run_rscons(args: %w[-f direct.rb])
  expect_eq(result.stderr, "")
  expect_eq(result.status, 0)
  expect_truthy(File.exist?("llvmtest.exe"))
  expect_match(`./llvmtest.exe`, /hello again/)
end

run_tests
