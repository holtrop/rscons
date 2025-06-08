require 'fileutils'
require "open3"
require "set"
require "tmpdir"

describe Rscons do

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

  before(:all) do
    @statics = {}
    @build_test_run_base_dir = File.expand_path("build_test_run")
    @run_results = Struct.new(:stdout, :stderr, :status)
    @owd = Dir.pwd
    rm_rf(@build_test_run_base_dir)
    FileUtils.mkdir_p(@build_test_run_base_dir)
  end

  before(:each) do
    @statics[:example_id] ||= 0
    @statics[:example_id] += 1
    @build_test_run_dir = "#{@build_test_run_base_dir}/test#{@statics[:example_id]}"
  end

  after(:each) do |example|
    Dir.chdir(@owd)
    if example.exception
      @statics[:keep_test_run_dir] = true
      message = "Leaving #{@build_test_run_dir} for inspection due to test failure"
      if example.exception.backtrace.find {|e| e =~ %r{^(.*/#{File.basename(__FILE__)}:\d+)}}
        message += " (#{$1})"
      end
      puts "\n#{message}"
    else
      rm_rf(@build_test_run_dir)
    end
  end

  after(:all) do
    unless @statics[:keep_test_run_dir]
      rm_rf(@build_test_run_base_dir)
    end
  end

  let(:passenv) {{}}

  def test_dir(build_test_directory)
    Dir.chdir(@owd)
    rm_rf(@build_test_run_dir)
    FileUtils.cp_r("build_tests/#{build_test_directory}", @build_test_run_dir)
    FileUtils.mkdir("#{@build_test_run_dir}/_bin")
    Dir.chdir(@build_test_run_dir)
  end

  def create_exe(exe_name, contents)
    exe_file = "#{@build_test_run_dir}/_bin/#{exe_name}"
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
    args = Array(options[:args]) || []
    if ENV["dist_specs"]
      exe = "#{@owd}/test/rscons.rb"
    else
      exe = "#{@owd}/bin/rscons"
    end
    command = %W[ruby -I. -r _simplecov_setup #{exe}] + args
    @statics[:build_test_id] ||= 0
    @statics[:build_test_id] += 1
    command_prefix =
      if ENV["partial_specs"]
        "p"
      else
        "b"
      end
    command_name = "#{command_prefix}#{@statics[:build_test_id]}"
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
    root(#{@owd.inspect})
    command_name(#{command_name.inspect})
    filters.clear
    add_filter do |src|
      !(src.filename[SimpleCov.root])
    end
    formatter(MyFormatter)
  end
end
# force color off
ENV["TERM"] = nil
#{options[:ruby_setup_code]}
EOF
      unless ENV["dist_specs"]
        fh.puts %[$LOAD_PATH.unshift(#{@owd.inspect} + "/lib")]
      end
    end
    stdout, stderr, status = nil, nil, nil
    Bundler.with_unbundled_env do
      env = ENV.to_h
      env.merge!(passenv)
      path = ["#{@build_test_run_dir}/_bin", "#{env["PATH"]}"]
      if options[:path]
        path = Array(options[:path]) + path
      end
      env["PATH"] = path.join(File::PATH_SEPARATOR)
      stdout, stderr, status = Open3.capture3(env, *command)
      File.open("#{@build_test_run_dir}/.stdout", "wb") do |fh|
        fh.write(stdout)
      end
      File.open("#{@build_test_run_dir}/.stderr", "wb") do |fh|
        fh.write(stderr)
      end
    end
    # Remove output lines generated as a result of the test environment
    stderr = stderr.lines.find_all do |line|
      not (line =~ /Warning: coverage data provided by Coverage.*exceeds number of lines/)
    end.join
    @run_results.new(stdout, stderr, status)
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

  ###########################################################################
  # Tests
  ###########################################################################

  it 'builds a C program with one source file' do
    test_dir('simple')
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(File.exist?('build/o/simple.c.o')).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C program\n"
  end

  it "processes the environment when created within a task" do
    test_dir("simple")
    result = run_rscons(args: %w[-f env_in_task.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("build/o/simple.c.o")).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C program\n"
  end

  it "uses the build directory specified with -b" do
    test_dir("simple")
    result = run_rscons(args: %w[-b b])
    expect(result.stderr).to eq ""
    expect(Dir.exist?("build")).to be_falsey
    expect(File.exist?("b/o/simple.c.o")).to be_truthy
  end

  it "uses the build directory specified by an environment variable" do
    test_dir("simple")
    passenv["RSCONS_BUILD_DIR"] = "b2"
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(Dir.exist?("build")).to be_falsey
    expect(File.exist?("b2/o/simple.c.o")).to be_truthy
  end

  it "allows specifying a Builder object as the source to another build target" do
    test_dir("simple")
    result = run_rscons(args: %w[-f builder_as_source.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("simple.o")).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C program\n"
  end

  it 'prints commands as they are executed' do
    test_dir('simple')
    result = run_rscons(args: %w[-f command.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o build/o/simple.c.o -MMD -MF build/o/simple.c.o.mf simple.c},
      %r{gcc -o simple.exe build/o/simple.c.o},
    ])
  end

  it 'prints short representations of the commands being executed' do
    test_dir('header')
    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling header.c},
      %r{Linking header.exe},
    ])
  end

  it 'builds a C program with one source file and one header file' do
    test_dir('header')
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(File.exist?('build/o/header.c.o')).to be_truthy
    expect(nr(`./header.exe`)).to eq "The value is 2\n"
  end

  it 'rebuilds a C module when a header it depends on changes' do
    test_dir('header')
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(nr(`./header.exe`)).to eq "The value is 2\n"
    file_sub('header.h') {|line| line.sub(/2/, '5')}
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(nr(`./header.exe`)).to eq "The value is 5\n"
  end

  it 'does not rebuild a C module when its dependencies have not changed' do
    test_dir('header')
    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling header.c},
      %r{Linking header.exe},
    ])
    expect(nr(`./header.exe`)).to eq "The value is 2\n"
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(result.stdout).to eq ""
  end

  it "does not rebuild a C module when only the file's timestamp has changed" do
    test_dir('header')
    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling header.c},
      %r{Linking header.exe},
    ])
    expect(nr(`./header.exe`)).to eq "The value is 2\n"
    sleep 0.05
    file_sub('header.c') {|line| line}
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(result.stdout).to eq ""
  end

  it 're-links a program when the link flags have changed' do
    test_dir('simple')
    result = run_rscons(args: %w[-f command.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o build/o/simple.c.o -MMD -MF build/o/simple.c.o.mf simple.c},
      %r{gcc -o simple.exe build/o/simple.c.o},
    ])
    result = run_rscons(args: %w[-f link_flag_change.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -o simple.exe build/o/simple.c.o -Llibdir},
    ])
  end

  it "supports barriers and prevents parallelizing builders across them" do
    test_dir "simple"
    result = run_rscons(args: %w[-f barrier.rb -j 3])
    expect(result.stderr).to eq ""
    slines = lines(result.stdout).select {|line| line =~ /T\d/}
    expect(slines).to eq [
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
    ]
  end

  it "expands target and source paths starting with ^/ and ^^/" do
    test_dir("typical")
    result = run_rscons(args: %w[-f carat.rb -b bld])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o bld/one.o -MMD -MF bld/one.o.mf -Isrc -Isrc/one -Isrc/two bld/one.c},
      %r{gcc -c -o bld/two.c.o -MMD -MF bld/two.c.o.mf -Isrc -Isrc/one -Isrc/two bld/two.c},
      %r{gcc -o bld/program.exe bld/one.o bld/two.c.o},
    ])
  end

  it 'supports simple builders' do
    test_dir('json_to_yaml')
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(File.exist?('foo.yml')).to be_truthy
    expect(nr(IO.read('foo.yml'))).to eq("---\nkey: value\n")
  end

  it "raises an error when a side-effect file is registered for a build target that is not registered" do
    test_dir "simple"
    result = run_rscons(args: %w[-f error_produces_nonexistent_target.rb])
    expect(result.stderr).to match /Could not find a registered build target "foo"/
  end

  context "clean task" do
    it 'cleans built files' do
      test_dir("simple")
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(`./simple.exe`).to match /This is a simple C program/
      expect(File.exist?('build/o/simple.c.o')).to be_truthy
      result = run_rscons(args: %w[clean])
      expect(File.exist?('build/o/simple.c.o')).to be_falsey
      expect(File.exist?('build/o')).to be_falsey
      expect(File.exist?('simple.exe')).to be_falsey
      expect(File.exist?('simple.c')).to be_truthy
    end

    it "executes custom clean action blocks" do
      test_dir("simple")
      result = run_rscons(args: %w[-f clean.rb])
      expect(result.stderr).to eq ""
      expect(File.exist?("build/o/simple.c.o")).to be_truthy
      result = run_rscons(args: %w[-f clean.rb clean])
      expect(result.stderr).to eq ""
      expect(result.stdout).to match %r{custom clean action}
      expect(File.exist?("build/o/simple.c.o")).to be_falsey
    end

    it "does not process environments" do
      test_dir("simple")
      result = run_rscons(args: %w[clean])
      expect(result.stderr).to eq ""
      expect(File.exist?('build/o/simple.c.o')).to be_falsey
      expect(File.exist?('build/o')).to be_falsey
      expect(File.exist?('simple.exe')).to be_falsey
      expect(File.exist?('simple.c')).to be_truthy
      expect(result.stdout).to eq ""
    end

    it 'does not clean created directories if other non-rscons-generated files reside there' do
      test_dir("simple")
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(`./simple.exe`).to match /This is a simple C program/
      expect(File.exist?('build/o/simple.c.o')).to be_truthy
      File.open('build/o/dum', 'w') { |fh| fh.puts "dum" }
      result = run_rscons(args: %w[clean])
      expect(File.exist?('build/o')).to be_truthy
      expect(File.exist?('build/o/dum')).to be_truthy
    end

    it "removes built files but not installed files" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""
        expect(File.exist?("#{prefix}/bin/program.exe")).to be_truthy
        expect(File.exist?("build/o/src/one/one.c.o")).to be_truthy

        result = run_rscons(args: %w[-f install.rb clean])
        expect(result.stderr).to eq ""
        expect(File.exist?("#{prefix}/bin/program.exe")).to be_truthy
        expect(File.exist?("build/o/src/one/one.c.o")).to be_falsey
      end
    end

    it "does not remove install cache entries" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb clean])
        expect(result.stderr).to eq ""
        expect(File.exist?("#{prefix}/bin/program.exe")).to be_truthy
        expect(File.exist?("build/o/src/one/one.c.o")).to be_falsey

        result = run_rscons(args: %w[-f install.rb -v uninstall])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match %r{Removing #{prefix}/bin/program.exe}
        expect(Dir.entries(prefix)).to match_array %w[. ..]
      end
    end
  end

  it 'allows Ruby classes as custom builders to be used to construct files' do
    test_dir('custom_builder')
    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling program.c},
      %r{Linking program.exe},
    ])
    expect(File.exist?('inc.h')).to be_truthy
    expect(nr(`./program.exe`)).to eq "The value is 5678\n"
  end

  it 'supports custom builders with multiple targets' do
    test_dir('custom_builder')
    result = run_rscons(args: %w[-f multiple_targets.rb])
    expect(result.stderr).to eq ""
    slines = lines(result.stdout)
    verify_lines(slines, [
      %r{CHGen inc.c},
      %r{Compiling program.c},
      %r{Compiling inc.c},
      %r{Linking program.exe},
    ])
    expect(File.exist?("inc.c")).to be_truthy
    expect(File.exist?("inc.h")).to be_truthy
    expect(nr(`./program.exe`)).to eq "The value is 42\n"

    File.open("inc.c", "w") {|fh| fh.puts "int THE_VALUE = 33;"}
    result = run_rscons(args: %w[-f multiple_targets.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [%r{CHGen inc.c}])
    expect(nr(`./program.exe`)).to eq "The value is 42\n"
  end

  it 'raises an error when a custom builder returns an invalid value from #run' do
    test_dir("custom_builder")
    result = run_rscons(args: %w[-f error_run_return_value.rb])
    expect(result.stderr).to match /Unrecognized MyBuilder builder return value: "hi"/
    expect(result.status).to_not eq 0
  end

  it 'raises an error when a custom builder returns an invalid value using Builder#wait_for' do
    test_dir("custom_builder")
    result = run_rscons(args: %w[-f error_wait_for.rb])
    expect(result.stderr).to match /Unrecognized MyBuilder builder return item: 1/
    expect(result.status).to_not eq 0
  end

  it 'supports a Builder waiting for a custom Thread object' do
    test_dir "custom_builder"
    result = run_rscons(args: %w[-f wait_for_thread.rb])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    verify_lines(lines(result.stdout), [%r{MyBuilder foo}])
    expect(File.exist?("foo")).to be_truthy
  end

  it 'supports a Builder waiting for another Builder' do
    test_dir "simple"
    result = run_rscons(args: %w[-f builder_wait_for_builder.rb])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    verify_lines(lines(result.stdout), [%r{MyObject simple.o}])
    expect(File.exist?("simple.o")).to be_truthy
    expect(File.exist?("simple.exe")).to be_truthy
  end

  it 'allows cloning Environment objects' do
    test_dir('clone_env')
    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o build/dbg/o/src/program.c.o -MMD -MF build/dbg/o/src/program.c.o.mf '-DSTRING="Debug Version"' -O2 src/program.c},
      %r{gcc -o program-debug.exe build/dbg/o/src/program.c.o},
      %r{gcc -c -o build/rls/o/src/program.c.o -MMD -MF build/rls/o/src/program.c.o.mf '-DSTRING="Release Version"' -O2 src/program.c},
      %r{gcc -o program-release.exe build/rls/o/src/program.c.o},
    ])
  end

  it 'clones all attributes of an Environment object by default' do
    test_dir('clone_env')
    result = run_rscons(args: %w[-f clone_all.rb])
    expect(result.stderr).to eq ""
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

  it 'builds a C++ program with one source file' do
    test_dir('simple_cc')
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(File.exist?('build/o/simple.cc.o')).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C++ program\n"
  end

  it "links with the C++ linker when object files were built from C++ sources" do
    test_dir("simple_cc")
    result = run_rscons(args: %w[-f link_objects.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("simple.o")).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C++ program\n"
  end

  it 'allows overriding construction variables for individual builder calls' do
    test_dir('two_sources')
    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o one.o -MMD -MF build/o/one.o.mf -DONE one.c},
      %r{gcc -c -o build/o/two.c.o -MMD -MF build/o/two.c.o.mf two.c},
      %r{gcc -o two_sources.exe one.o build/o/two.c.o},
    ])
    expect(File.exist?("two_sources.exe")).to be_truthy
    expect(nr(`./two_sources.exe`)).to eq "This is a C program with two sources.\n"
  end

  it 'builds a static library archive' do
    test_dir('library')
    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o build/o/two.c.o -MMD -MF build/o/two.c.o.mf -Dmake_lib two.c},
      %r{gcc -c -o build/o/three.c.o -MMD -MF build/o/three.c.o.mf -Dmake_lib three.c},
      %r{ar rcs libmylib.a build/o/two.c.o build/o/three.c.o},
      %r{gcc -c -o build/o/one.c.o -MMD -MF build/o/one.c.o.mf one.c},
      %r{gcc -o library.exe build/o/one.c.o -L. -lmylib},
    ])
    expect(File.exist?("library.exe")).to be_truthy
    ar_t = nr(`ar t libmylib.a`)
    expect(ar_t).to match %r{\btwo.c.o\b}
    expect(ar_t).to match %r{\bthree.c.o\b}
  end

  it 'supports build hooks to override construction variables' do
    test_dir("typical")
    result = run_rscons(args: %w[-f build_hooks.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o build/o/src/one/one.c.o -MMD -MF build/o/src/one/one.c.o.mf -Isrc/one -Isrc/two -O1 src/one/one.c},
      %r{gcc -c -o build/o/src/two/two.c.o -MMD -MF build/o/src/two/two.c.o.mf -Isrc/one -Isrc/two -O2 src/two/two.c},
      %r{gcc -o build_hook.exe build/o/src/one/one.c.o build/o/src/two/two.c.o},
    ])
    expect(nr(`./build_hook.exe`)).to eq "Hello from two()\n"
  end

  it 'supports build hooks to override the entire vars hash' do
    test_dir("typical")
    result = run_rscons(args: %w[-f build_hooks_override_vars.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{gcc -c -o one.o -MMD -MF build/o/one.o.mf -Isrc -Isrc/one -Isrc/two -O1 src/two/two.c},
      %r{gcc -c -o two.o -MMD -MF build/o/two.o.mf -Isrc -Isrc/one -Isrc/two -O2 src/two/two.c},
    ])
    expect(File.exist?('one.o')).to be_truthy
    expect(File.exist?('two.o')).to be_truthy
  end

  it 'rebuilds when user-specified dependencies change' do
    test_dir('simple')

    File.open("program.ld", "w") {|fh| fh.puts("1")}
    result = run_rscons(args: %w[-f user_dependencies.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.exe},
    ])
    expect(File.exist?('build/o/simple.c.o')).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C program\n"

    File.open("program.ld", "w") {|fh| fh.puts("2")}
    result = run_rscons(args: %w[-f user_dependencies.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [%r{Linking simple.exe}])

    File.unlink("program.ld")
    result = run_rscons(args: %w[-f user_dependencies.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [%r{Linking simple.exe}])

    result = run_rscons(args: %w[-f user_dependencies.rb])
    expect(result.stderr).to eq ""
    expect(result.stdout).to eq ""
  end

  it "rebuilds when user-specified dependencies using ^ change" do
    test_dir("simple")

    passenv["file_contents"] = "1"
    result = run_rscons(args: %w[-f user_dependencies_carat.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking .*simple.exe},
    ])

    passenv["file_contents"] = "2"
    result = run_rscons(args: %w[-f user_dependencies_carat.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [%r{Linking .*simple.exe}])

    result = run_rscons(args: %w[-f user_dependencies_carat.rb])
    expect(result.stderr).to eq ""
    expect(result.stdout).to eq ""
  end

  unless RUBY_PLATFORM =~ /mingw|msys|darwin/
    it "supports building D sources with gdc" do
      test_dir("d")
      result = run_rscons
      expect(result.stderr).to eq ""
      slines = lines(result.stdout)
      verify_lines(slines, [%r{gdc -c -o build/o/main.d.o -MMD -MF build/o/main.d.o.mf main.d}])
      verify_lines(slines, [%r{gdc -c -o build/o/mod.d.o -MMD -MF build/o/mod.d.o.mf mod.d}])
      verify_lines(slines, [%r{gdc -o hello-d.exe build/o/main.d.o build/o/mod.d.o}])
      expect(`./hello-d.exe`.rstrip).to eq "Hello from D, value is 42!"
    end
  end

  it "supports building D sources with ldc2" do
    test_dir("d")
    result = run_rscons(args: %w[-f build-ldc2.rb])
    expect(result.stderr).to eq ""
    slines = lines(result.stdout)
    verify_lines(slines, [%r{ldc2 -c -of build/o/main.d.o(bj)? -deps=build/o/main.d.o(bj)?.mf main.d}])
    verify_lines(slines, [%r{ldc2 -c -of build/o/mod.d.o(bj)? -deps=build/o/mod.d.o(bj)?.mf mod.d}])
    verify_lines(slines, [%r{ldc2 -of hello-d.exe build/o/main.d.o(bj)? build/o/mod.d.o(bj)?}])
    expect(`./hello-d.exe`.rstrip).to eq "Hello from D, value is 42!"
  end

  it "rebuilds D modules with ldc2 when deep dependencies change" do
    test_dir("d")
    result = run_rscons(args: %w[-f build-ldc2.rb])
    expect(result.stderr).to eq ""
    slines = lines(result.stdout)
    verify_lines(slines, [%r{ldc2 -c -of build/o/main.d.o(bj)? -deps=build/o/main.d.o(bj)?.mf main.d}])
    verify_lines(slines, [%r{ldc2 -c -of build/o/mod.d.o(bj)? -deps=build/o/mod.d.o(bj)?.mf mod.d}])
    verify_lines(slines, [%r{ldc2 -of hello-d.exe build/o/main.d.o(bj)? build/o/mod.d.o(bj)?}])
    expect(`./hello-d.exe`.rstrip).to eq "Hello from D, value is 42!"
    contents = File.read("mod.d", mode: "rb").sub("42", "33")
    File.open("mod.d", "wb") do |fh|
      fh.write(contents)
    end
    result = run_rscons(args: %w[-f build-ldc2.rb])
    expect(result.stderr).to eq ""
    slines = lines(result.stdout)
    verify_lines(slines, [%r{ldc2 -c -of build/o/main.d.o(bj)? -deps=build/o/main.d.o(bj)?.mf main.d}])
    verify_lines(slines, [%r{ldc2 -c -of build/o/mod.d.o(bj)? -deps=build/o/mod.d.o(bj)?.mf mod.d}])
    verify_lines(slines, [%r{ldc2 -of hello-d.exe build/o/main.d.o(bj)? build/o/mod.d.o(bj)?}])
    expect(`./hello-d.exe`.rstrip).to eq "Hello from D, value is 33!"
  end

  unless RUBY_PLATFORM =~ /mingw|msys|darwin/
    it "links with the D linker when object files were built from D sources" do
      test_dir("d")
      result = run_rscons(args: %w[-f link_objects.rb])
      expect(result.stderr).to eq ""
      expect(File.exist?("main.o")).to be_truthy
      expect(File.exist?("mod.o")).to be_truthy
      expect(`./hello-d.exe`.rstrip).to eq "Hello from D, value is 42!"
    end

    it "does dependency generation for D sources" do
      test_dir("d")
      result = run_rscons
      expect(result.stderr).to eq ""
      slines = lines(result.stdout)
      verify_lines(slines, [%r{gdc -c -o build/o/main.d.o -MMD -MF build/o/main.d.o.mf main.d}])
      verify_lines(slines, [%r{gdc -c -o build/o/mod.d.o -MMD -MF build/o/mod.d.o.mf mod.d}])
      verify_lines(slines, [%r{gdc -o hello-d.exe build/o/main.d.o build/o/mod.d.o}])
      expect(`./hello-d.exe`.rstrip).to eq "Hello from D, value is 42!"
      fcontents = File.read("mod.d", mode: "rb").sub("42", "33")
      File.open("mod.d", "wb") {|fh| fh.write(fcontents)}
      result = run_rscons
      expect(result.stderr).to eq ""
      slines = lines(result.stdout)
      verify_lines(slines, [%r{gdc -c -o build/o/main.d.o -MMD -MF build/o/main.d.o.mf main.d}])
      verify_lines(slines, [%r{gdc -c -o build/o/mod.d.o -MMD -MF build/o/mod.d.o.mf mod.d}])
      verify_lines(slines, [%r{gdc -o hello-d.exe build/o/main.d.o build/o/mod.d.o}])
      expect(`./hello-d.exe`.rstrip).to eq "Hello from D, value is 33!"
    end

    it "creates shared libraries using D" do
      test_dir("shared_library")

      result = run_rscons(args: %w[-f shared_library_d.rb])
      expect(result.stderr).to eq ""
      slines = lines(result.stdout)
      if RUBY_PLATFORM =~ /mingw|msys/
        verify_lines(slines, [%r{Linking mine.dll}])
      else
        verify_lines(slines, [%r{Linking libmine.so}])
      end
    end
  end

  it "supports disassembling object files" do
    test_dir("simple")

    result = run_rscons(args: %w[-f disassemble.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("simple.txt")).to be_truthy
    expect(File.read("simple.txt")).to match /Disassembly of section/

    result = run_rscons(args: %w[-f disassemble.rb])
    expect(result.stderr).to eq ""
    expect(result.stdout).to eq ""
  end

  it "supports preprocessing C sources" do
    test_dir("simple")
    result = run_rscons(args: %w[-f preprocess.rb])
    expect(result.stderr).to eq ""
    expect(File.read("simplepp.c")).to match /# \d+ "simple.c"/
    expect(nr(`./simple.exe`)).to eq "This is a simple C program\n"
  end

  it "supports preprocessing C++ sources" do
    test_dir("simple_cc")
    result = run_rscons(args: %w[-f preprocess.rb])
    expect(result.stderr).to eq ""
    expect(File.read("simplepp.cc")).to match /# \d+ "simple.cc"/
    expect(nr(`./simple.exe`)).to eq "This is a simple C++ program\n"
  end

  it "supports invoking builders with no sources" do
    test_dir("simple")
    result = run_rscons(args: %w[-f builder_no_sources.rb])
    expect(result.stderr).to eq ""
  end

  it "expands construction variables in builder target and sources before invoking the builder" do
    test_dir('custom_builder')
    result = run_rscons(args: %w[-f cvar_expansion.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling program.c},
      %r{Linking program.exe},
    ])
    expect(File.exist?('inc.h')).to be_truthy
    expect(nr(`./program.exe`)).to eq "The value is 678\n"
  end

  it "supports lambdas as construction variable values" do
    test_dir "custom_builder"
    result = run_rscons(args: %w[-f cvar_lambda.rb])
    expect(result.stderr).to eq ""
    expect(nr(`./program.exe`)).to eq "The value is 5678\n"
  end

  it "supports registering build targets from within a build hook" do
    test_dir("simple")
    result = run_rscons(args: %w[-f register_target_in_build_hook.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("build/o/simple.c.o")).to be_truthy
    expect(File.exist?("build/o/simple.c.o.txt")).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C program\n"
  end

  it "supports multiple values for CXXSUFFIX" do
    test_dir("simple_cc")
    File.open("other.cccc", "w") {|fh| fh.puts}
    result = run_rscons(args: %w[-f cxxsuffix.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("build/o/simple.cc.o")).to be_truthy
    expect(File.exist?("build/o/other.cccc.o")).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C++ program\n"
  end

  it "supports multiple values for CSUFFIX" do
    test_dir("typical")
    FileUtils.mv("src/one/one.c", "src/one/one.yargh")
    result = run_rscons(args: %w[-f csuffix.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("build/o/src/one/one.yargh.o")).to be_truthy
    expect(File.exist?("build/o/src/two/two.c.o")).to be_truthy
    expect(nr(`./program.exe`)).to eq "Hello from two()\n"
  end

  it "supports multiple values for OBJSUFFIX" do
    test_dir("two_sources")
    result = run_rscons(args: %w[-f objsuffix.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("two_sources.exe")).to be_truthy
    expect(File.exist?("one.oooo")).to be_truthy
    expect(File.exist?("two.ooo")).to be_truthy
    expect(nr(`./two_sources.exe`)).to eq "This is a C program with two sources.\n"
  end

  it "supports multiple values for LIBSUFFIX" do
    test_dir("two_sources")
    result = run_rscons(args: %w[-f libsuffix.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("two_sources.exe")).to be_truthy
    expect(nr(`./two_sources.exe`)).to eq "This is a C program with two sources.\n"
  end

  it "supports multiple values for ASSUFFIX" do
    test_dir("two_sources")
    result = run_rscons(args: %w[-f assuffix.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling one.c},
      %r{Compiling two.c},
      %r{Assembling one.ssss},
      %r{Assembling two.sss},
      %r{Linking two_sources.exe},
    ])
    expect(File.exist?("two_sources.exe")).to be_truthy
    expect(nr(`./two_sources.exe`)).to eq "This is a C program with two sources.\n"
  end

  it "supports dumping an Environment's construction variables" do
    test_dir("simple")
    result = run_rscons(args: %w[-f dump.rb])
    expect(result.stderr).to eq ""
    slines = lines(result.stdout)
    expect(slines.include?(%{:foo => :bar})).to be_truthy
    expect(slines.include?(%{CFLAGS => ["-O2", "-fomit-frame-pointer"]})).to be_truthy
    expect(slines.include?(%{CPPPATH => []})).to be_truthy
  end

  it "considers deep dependencies when deciding whether to rerun Preprocess builder" do
    test_dir("preprocess")

    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [%r{Preprocessing foo.h => pp}])
    expect(File.read("pp")).to match(%r{xyz42abc}m)

    result = run_rscons
    expect(result.stderr).to eq ""
    expect(result.stdout).to eq ""

    File.open("bar.h", "w") do |fh|
      fh.puts "#define BAR abc88xyz"
    end
    result = run_rscons
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [%r{Preprocessing foo.h => pp}])
    expect(File.read("pp")).to match(%r{abc88xyz}m)
  end

  it "allows construction variable references which expand to arrays in sources of a build target" do
    test_dir("simple")
    result = run_rscons(args: %w[-f cvar_array.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("build/o/simple.c.o")).to be_truthy
    expect(nr(`./simple.exe`)).to eq "This is a simple C program\n"
  end

  it "supports registering multiple build targets with the same target path" do
    test_dir("typical")
    result = run_rscons(args: %w[-f multiple_targets_same_name.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("one.o")).to be_truthy
    verify_lines(lines(result.stdout), [
      %r{Compiling src/one/one.c},
      %r{Compiling src/two/two.c},
    ])
  end

  it "expands target and source paths when builders are registered in build hooks" do
    test_dir("typical")
    result = run_rscons(args: %w[-f post_build_hook_expansion.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("one.o")).to be_truthy
    expect(File.exist?("two.o")).to be_truthy
    verify_lines(lines(result.stdout), [
      %r{Compiling src/one/one.c},
      %r{Compiling src/two/two.c},
    ])
  end

  it "does not re-run previously successful builders if one fails" do
    test_dir('simple')
    File.open("two.c", "w") do |fh|
      fh.puts("FOO")
    end
    result = run_rscons(args: %w[-f cache_successful_builds_when_one_fails.rb -j1])
    expect(result.stderr).to match /FOO/
    expect(File.exist?("simple.o")).to be_truthy
    expect(File.exist?("two.o")).to be_falsey

    File.open("two.c", "w") {|fh|}
    result = run_rscons(args: %w[-f cache_successful_builds_when_one_fails.rb -j1])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling two.c},
    ])
  end

  it "allows overriding PROGSUFFIX" do
    test_dir("simple")
    result = run_rscons(args: %w[-f progsuffix.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.out},
    ])
  end

  it "does not use PROGSUFFIX when the Program target name expands to a value already containing an extension" do
    test_dir("simple")
    result = run_rscons(args: %w[-f progsuffix2.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.out},
    ])
  end

  it "allows overriding PROGSUFFIX from extra vars passed in to the builder" do
    test_dir("simple")
    result = run_rscons(args: %w[-f progsuffix3.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [
      %r{Compiling simple.c},
      %r{Linking simple.xyz},
    ])
  end

  it "creates object files under the build root for absolute source paths" do
    test_dir("simple")
    result = run_rscons(args: %w[-f absolute_source_path.rb])
    expect(result.stderr).to eq ""
    slines = lines(result.stdout)
    verify_lines(slines, [%r{build/o/.*/abs\.c.o$}])
    verify_lines(slines, [%r{\babs.exe\b}])
  end

  it "creates object files next to the source file for source files in the build root" do
    test_dir "simple"
    result = run_rscons(args: %w[-f build_root_source_path.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("build/e/o/build/e/src/foo.c.o")).to be_falsey
    expect(File.exist?("build/e/src/foo.c.o")).to be_truthy
  end

  it "creates shared libraries" do
    test_dir("shared_library")

    result = run_rscons
    expect(result.stderr).to eq ""
    slines = lines(result.stdout)
    if RUBY_PLATFORM =~ /mingw|msys/
      verify_lines(slines, [%r{Linking mine.dll}])
      expect(File.exist?("mine.dll")).to be_truthy
    else
      verify_lines(slines, [%r{Linking libmine.so}])
      expect(File.exist?("libmine.so")).to be_truthy
    end

    result = run_rscons
    expect(result.stderr).to eq ""
    expect(result.stdout).to eq ""

    ld_library_path_prefix = (RUBY_PLATFORM =~ /mingw|msys/ ? "" : "LD_LIBRARY_PATH=. ")
    expect(`#{ld_library_path_prefix}./test-shared.exe`).to match /Hi from one/
    expect(`./test-static.exe`).to match /Hi from one/
  end

  it "creates shared libraries using assembly" do
    test_dir("shared_library")

    result = run_rscons(args: %w[-f shared_library_as.rb])
    expect(result.stderr).to eq ""
    expect(File.exist?("file.S")).to be_truthy
  end

  it "creates shared libraries using C++" do
    test_dir("shared_library")

    result = run_rscons(args: %w[-f shared_library_cxx.rb])
    expect(result.stderr).to eq ""
    slines = lines(result.stdout)
    if RUBY_PLATFORM =~ /mingw|msys/
      verify_lines(slines, [%r{Linking mine.dll}])
    else
      verify_lines(slines, [%r{Linking libmine.so}])
    end

    result = run_rscons(args: %w[-f shared_library_cxx.rb])
    expect(result.stderr).to eq ""
    expect(result.stdout).to eq ""

    ld_library_path_prefix = (RUBY_PLATFORM =~ /mingw|msys/ ? "" : "LD_LIBRARY_PATH=. ")
    expect(`#{ld_library_path_prefix}./test-shared.exe`).to match /Hi from one/
    expect(`./test-static.exe`).to match /Hi from one/
  end

  it "raises an error for a circular dependency" do
    test_dir("simple")
    result = run_rscons(args: %w[-f error_circular_dependency.rb])
    expect(result.stderr).to match /Possible circular dependency for (foo|bar|baz)/
    expect(result.status).to_not eq 0
  end

  it "raises an error for a circular dependency where a build target contains itself in its source list" do
    test_dir("simple")
    result = run_rscons(args: %w[-f error_circular_dependency2.rb])
    expect(result.stderr).to match /Possible circular dependency for foo/
    expect(result.status).to_not eq 0
  end

  it "orders builds to respect user dependencies" do
    test_dir("simple")
    result = run_rscons(args: %w[-f user_dep_build_order.rb -j4])
    expect(result.stderr).to eq ""
  end

  it "waits for all parallelized builds to complete if one fails" do
    test_dir("simple")
    result = run_rscons(args: %w[-f wait_for_builds_on_failure.rb -j4])
    expect(result.status).to_not eq 0
    expect(result.stderr).to match /Failed to build foo_1/
    expect(result.stderr).to match /Failed to build foo_2/
    expect(result.stderr).to match /Failed to build foo_3/
    expect(result.stderr).to match /Failed to build foo_4/
  end

  it "clones n_threads attribute when cloning an Environment" do
    test_dir("simple")
    result = run_rscons(args: %w[-f clone_n_threads.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [/165/])
  end

  it "prints a builder's short description with 'command' echo mode if there is no command" do
    test_dir("typical")

    result = run_rscons(args: %w[-f echo_command_ruby_builder.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [%r{Copy echo_command_ruby_builder.rb => copy.rb}])
  end

  it "supports a string for a builder's echoed 'command' with Environment#print_builder_run_message" do
    test_dir("typical")

    result = run_rscons(args: %w[-f echo_command_string.rb])
    expect(result.stderr).to eq ""
    verify_lines(lines(result.stdout), [%r{MyBuilder foo command}])
  end

  it "stores the failed command for later display with -F command line option" do
    test_dir("simple")

    File.open("simple.c", "wb") do |fh|
      fh.write("foo")
    end

    result = run_rscons
    expect(result.stderr).to match /Failed to build/
    expect(result.stderr).to match %r{^Use .*/rscons(\.rb)? -F.*to view the failed command log}
    expect(result.status).to_not eq 0

    result = run_rscons(args: %w[-F])
    expect(result.stderr).to eq ""
    expect(result.stdout).to match %r{Failed command \(1/1\):}
    expect(result.stdout).to match %r{^gcc -}
    expect(result.status).to eq 0
  end

  it "stores build artifacts in a directory according to Environment name" do
    test_dir "typical"

    result = run_rscons
    expect(File.exist?("build/typical/typical.exe")).to be_truthy
    expect(File.exist?("build/typical/o/src/one/one.c.o")).to be_truthy
  end

  it "names Environment during clone" do
    test_dir "typical"

    result = run_rscons(args: %w[-f clone_and_name.rb])
    expect(File.exist?("build/typical/typical.exe")).to be_truthy
    expect(File.exist?("build/typical/o/src/one/one.c.o")).to be_truthy
    expect(Dir.exist?("build/o")).to be_falsey
  end

  it "allows looking up environments by name" do
    test_dir "typical"

    result = run_rscons(args: %w[-f clone_with_lookup.rb])
    expect(File.exist?("build/typical/typical.exe")).to be_truthy
    expect(File.exist?("build/typical/o/src/one/one.c.o")).to be_truthy
    expect(Dir.exist?("build/first")).to be_falsey
  end

  context "colored output" do
    it "does not output in color with --color=off" do
      test_dir("simple")
      result = run_rscons(args: %w[--color=off])
      expect(result.stderr).to eq ""
      expect(result.stdout).to_not match(/\e\[/)
    end

    it "displays output in color with --color=force" do
      test_dir("simple")

      result = run_rscons(args: %w[--color=force])
      expect(result.stderr).to eq ""
      expect(result.stdout).to match(/\e\[/)

      File.open("simple.c", "wb") do |fh|
        fh.write("foobar")
      end
      result = run_rscons(args: %w[--color=force])
      expect(result.stderr).to match(/\e\[/)
    end
  end

  context "Lex and Yacc builders" do
    it "builds C files using flex and bison" do
      test_dir("lex_yacc")

      result = run_rscons
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Generating lexer source from lexer.l => lexer.c},
        %r{Generating parser source from parser.y => parser.c},
      ])

      result = run_rscons
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""
    end
  end

  context "Command builder" do
    it "allows executing an arbitrary command" do
      test_dir('simple')

      result = run_rscons(args: %w[-f command_builder.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{BuildIt simple.exe}])
      expect(nr(`./simple.exe`)).to eq "This is a simple C program\n"

      result = run_rscons(args: %w[-f command_builder.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""
    end

    it "allows redirecting standard output to a file" do
      test_dir("simple")

      result = run_rscons(args: %w[-f command_redirect.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Compiling simple.c},
        %r{My Disassemble simple.txt},
      ])
      expect(File.read("simple.txt")).to match /Disassembly of section/
    end
  end

  context "Directory builder" do
    it "creates the requested directory" do
      test_dir("simple")
      result = run_rscons(args: %w[-f directory.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Creating directory teh_dir}])
      expect(File.directory?("teh_dir")).to be_truthy
    end

    it "succeeds when the requested directory already exists" do
      test_dir("simple")
      FileUtils.mkdir("teh_dir")
      result = run_rscons(args: %w[-f directory.rb])
      expect(result.stderr).to eq ""
      expect(lines(result.stdout)).to_not include a_string_matching /Creating directory/
      expect(File.directory?("teh_dir")).to be_truthy
    end

    it "fails when the target path is a file" do
      test_dir("simple")
      FileUtils.touch("teh_dir")
      result = run_rscons(args: %w[-f directory.rb])
      expect(result.stderr).to match %r{Error: `teh_dir' already exists and is not a directory}
    end
  end

  context "Copy builder" do
    it "copies a file to the target file name" do
      test_dir("typical")

      result = run_rscons(args: %w[-f copy.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy copy.rb => inst.exe}])

      result = run_rscons(args: %w[-f copy.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""

      expect(File.exist?("inst.exe")).to be_truthy
      expect(File.read("inst.exe", mode: "rb")).to eq(File.read("copy.rb", mode: "rb"))

      FileUtils.rm("inst.exe")
      result = run_rscons(args: %w[-f copy.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy copy.rb => inst.exe}])
    end

    it "copies multiple files to the target directory name" do
      test_dir("typical")

      result = run_rscons(args: %w[-f copy_multiple.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy copy.rb \(\+1\) => dest}])

      result = run_rscons(args: %w[-f copy_multiple.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""

      expect(Dir.exist?("dest")).to be_truthy
      expect(File.exist?("dest/copy.rb")).to be_truthy
      expect(File.exist?("dest/copy_multiple.rb")).to be_truthy

      FileUtils.rm_rf("dest")
      result = run_rscons(args: %w[-f copy_multiple.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy copy.rb \(\+1\) => dest}])
    end

    it "copies a file to the target directory name" do
      test_dir("typical")

      result = run_rscons(args: %w[-f copy_directory.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy copy_directory.rb => copy}])
      expect(File.exist?("copy/copy_directory.rb")).to be_truthy
      expect(File.read("copy/copy_directory.rb", mode: "rb")).to eq(File.read("copy_directory.rb", mode: "rb"))

      result = run_rscons(args: %w[-f copy_directory.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""
    end

    it "copies a directory to the non-existent target directory name" do
      test_dir("typical")
      result = run_rscons(args: %w[-f copy_directory.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy src => noexist/src}])
      %w[src/one/one.c src/two/two.c src/two/two.h].each do |f|
        expect(File.exist?("noexist/#{f}")).to be_truthy
        expect(File.read("noexist/#{f}", mode: "rb")).to eq(File.read(f, mode: "rb"))
      end
    end

    it "copies a directory to the existent target directory name" do
      test_dir("typical")
      result = run_rscons(args: %w[-f copy_directory.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy src => exist/src}])
      %w[src/one/one.c src/two/two.c src/two/two.h].each do |f|
        expect(File.exist?("exist/#{f}")).to be_truthy
        expect(File.read("exist/#{f}", mode: "rb")).to eq(File.read(f, mode: "rb"))
      end
    end
  end

  context "phony targets" do
    it "allows specifying a Symbol as a target name and reruns the builder if the sources or command have changed" do
      test_dir("simple")

      result = run_rscons(args: %w[-f phony_target.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Compiling simple.c},
        %r{Linking simple.exe},
        %r{Checker simple.exe},
      ])

      result = run_rscons(args: %w[-f phony_target.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""

      FileUtils.cp("phony_target.rb", "phony_target2.rb")
      file_sub("phony_target2.rb") {|line| line.sub(/.*Program.*/, "")}
      File.open("simple.exe", "w") do |fh|
        fh.puts "Changed simple.exe"
      end
      result = run_rscons(args: %w[-f phony_target2.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Checker simple.exe},
      ])
    end
  end

  context "Environment#clear_targets" do
    it "clears registered targets" do
      test_dir("simple")
      result = run_rscons(args: %w[-f clear_targets.rb])
      expect(result.stderr).to eq ""
      expect(lines(result.stdout)).to_not include a_string_matching %r{Linking}
    end
  end

  context "Cache management" do
    it "prints a warning when the cache is corrupt" do
      test_dir("simple")
      FileUtils.mkdir("build")
      File.open("build/.rsconscache", "w") do |fh|
        fh.puts("[1]")
      end
      result = run_rscons
      expect(result.stderr).to match /Warning.*was corrupt. Contents:/
    end

    it "forces a build when the target file does not exist and is not in the cache" do
      test_dir("simple")
      expect(File.exist?("simple.exe")).to be_falsey
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(File.exist?("simple.exe")).to be_truthy
    end

    it "forces a build when the target file does exist but is not in the cache" do
      test_dir("simple")
      File.open("simple.exe", "wb") do |fh|
        fh.write("hi")
      end
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(File.exist?("simple.exe")).to be_truthy
      expect(File.read("simple.exe", mode: "rb")).to_not eq "hi"
    end

    it "forces a build when the target file exists and is in the cache but has changed since cached" do
      test_dir("simple")
      result = run_rscons
      expect(result.stderr).to eq ""
      File.open("simple.exe", "wb") do |fh|
        fh.write("hi")
      end
      test_dir("simple")
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(File.exist?("simple.exe")).to be_truthy
      expect(File.read("simple.exe", mode: "rb")).to_not eq "hi"
    end

    it "forces a build when the command changes" do
      test_dir("simple")

      result = run_rscons
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Compiling simple.c},
        %r{Linking simple.exe},
      ])

      result = run_rscons(args: %w[-f cache_command_change.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Linking simple.exe},
      ])
    end

    it "forces a build when there is a new dependency" do
      test_dir("simple")

      result = run_rscons(args: %w[-f cache_new_dep1.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Compiling simple.c},
        %r{Linking simple.exe},
      ])

      result = run_rscons(args: %w[-f cache_new_dep2.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Linking simple.exe},
      ])
    end

    it "forces a build when a dependency's checksum has changed" do
      test_dir("simple")

      result = run_rscons(args: %w[-f cache_dep_checksum_change.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy simple.c => simple.copy}])
      File.open("simple.c", "wb") do |fh|
        fh.write("hi")
      end

      result = run_rscons(args: %w[-f cache_dep_checksum_change.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{Copy simple.c => simple.copy}])
    end

    it "forces a rebuild with strict_deps=true when dependency order changes" do
      test_dir("two_sources")

      File.open("sources", "wb") do |fh|
        fh.write("one.o two.o")
      end
      result = run_rscons(args: %w[-f cache_strict_deps.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{gcc -o program.exe one.o two.o}])

      result = run_rscons(args: %w[-f cache_strict_deps.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""

      File.open("sources", "wb") do |fh|
        fh.write("two.o one.o")
      end
      result = run_rscons(args: %w[-f cache_strict_deps.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{gcc -o program.exe one.o two.o}])
    end

    it "forces a rebuild when there is a new user dependency" do
      test_dir("simple")

      File.open("foo", "wb") {|fh| fh.write("hi")}
      File.open("user_deps", "wb") {|fh| fh.write("")}
      result = run_rscons(args: %w[-f cache_user_dep.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Compiling simple.c},
        %r{Linking simple.exe},
      ])

      File.open("user_deps", "wb") {|fh| fh.write("foo")}
      result = run_rscons(args: %w[-f cache_user_dep.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Linking simple.exe},
      ])
    end

    it "forces a rebuild when a user dependency file checksum has changed" do
      test_dir("simple")

      File.open("foo", "wb") {|fh| fh.write("hi")}
      File.open("user_deps", "wb") {|fh| fh.write("foo")}
      result = run_rscons(args: %w[-f cache_user_dep.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Compiling simple.c},
        %r{Linking simple.exe},
      ])

      result = run_rscons(args: %w[-f cache_user_dep.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""

      File.open("foo", "wb") {|fh| fh.write("hi2")}
      result = run_rscons(args: %w[-f cache_user_dep.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{Linking simple.exe},
      ])
    end

    it "allows a VarSet to be passed in as the command parameter" do
      test_dir("simple")
      result = run_rscons(args: %w[-f cache_varset.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{TestBuilder foo},
      ])
      result = run_rscons(args: %w[-f cache_varset.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""
    end

    it "supports building multiple object files from sources with the same pathname and basename" do
      test_dir "multiple_basename"
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("foo.exe")).to be_truthy
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(result.stdout).to eq ""
      expect(result.status).to eq 0
    end

    it "allows prepending and appending to PATH" do
      test_dir "simple"
      result = run_rscons(args: %w[-f pathing.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to match /flex!/
      expect(result.stdout).to match /foobar!/
      expect(File.exist?("simple.o")).to be_truthy
    end

    it "writes the dependency file to the build root" do
      test_dir "simple"
      result = run_rscons(args: %w[-f distclean.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to match /Compiling simple\.c/
      expect(File.exist?("simple.o")).to be_truthy
      expect(File.exist?("simple.o.mf")).to be_falsey
      expect(File.exist?("build/o/simple.o.mf")).to be_truthy
    end

    context "debugging" do
      it "prints a message when the target does not exist" do
        test_dir("simple")
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Target foo\.o needs rebuilding because it does not exist on disk/
      end

      it "prints a message when there is no cached build information for the target" do
        test_dir("simple")
        FileUtils.touch("foo.o")
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Target foo\.o needs rebuilding because there is no cached build information for it/
      end

      it "prints a message when the target file has changed on disk" do
        test_dir("simple")
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        File.open("foo.o", "wb") {|fh| fh.puts "hi"}
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Target foo\.o needs rebuilding because it has been changed on disk since being built last/
      end

      it "prints a message when the command has changed" do
        test_dir("simple")
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        passenv["test"] = "command_change"
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Target foo\.o needs rebuilding because the command used to build it has changed/
      end

      it "prints a message when strict_deps is in use and the set of dependencies does not match" do
        test_dir("simple")
        passenv["test"] = "strict_deps1"
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        passenv["test"] = "strict_deps2"
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Target foo\.o needs rebuilding because the :strict_deps option is given and the set of dependencies does not match the previous set of dependencies/
      end

      it "prints a message when there is a new dependency" do
        test_dir("simple")
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        passenv["test"] = "new_dep"
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Target foo\.o needs rebuilding because there are new dependencies/
      end

      it "prints a message when there is a new user-specified dependency" do
        test_dir("simple")
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        passenv["test"] = "new_user_dep"
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Target foo\.o needs rebuilding because the set of user-specified dependency files has changed/
      end

      it "prints a message when a dependency file has changed" do
        test_dir("simple")
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        f = File.read("simple.c", mode: "rb")
        f += "\n"
        File.open("simple.c", "wb") do |fh|
          fh.write(f)
        end
        result = run_rscons(args: %w[-f cache_debugging.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Target foo\.o needs rebuilding because dependency file simple\.c has changed/
      end
    end
  end

  context "Object builder" do
    it "allows overriding CCCMD construction variable" do
      test_dir("simple")
      result = run_rscons(args: %w[-f override_cccmd.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{gcc -c -o simple.o -Dfoobar simple.c},
      ])
    end

    it "allows overriding DEPFILESUFFIX construction variable" do
      test_dir("simple")
      result = run_rscons(args: %w[-f override_depfilesuffix.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{gcc -c -o simple.o -MMD -MF build/o/simple.o.deppy simple.c},
      ])
    end

    it "raises an error when given a source file with an unknown suffix" do
      test_dir("simple")
      result = run_rscons(args: %w[-f error_unknown_suffix.rb])
      expect(result.stderr).to match /Unknown input file type: "foo.xyz"/
    end
  end

  context "SharedObject builder" do
    it "raises an error when given a source file with an unknown suffix" do
      test_dir("shared_library")
      result = run_rscons(args: %w[-f error_unknown_suffix.rb])
      expect(result.stderr).to match /Unknown input file type: "foo.xyz"/
    end
  end

  context "Library builder" do
    it "allows overriding ARCMD construction variable" do
      test_dir("library")
      result = run_rscons(args: %w[-f override_arcmd.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [%r{ar rc lib.a build/o/one.c.o build/o/three.c.o build/o/two.c.o}])
    end

    it "allows passing object files as sources" do
      test_dir("library")
      result = run_rscons(args: %w[-f library_from_object.rb])
      expect(result.stderr).to eq ""
      expect(File.exist?("two.o")).to be_truthy
      verify_lines(lines(result.stdout), [%r{Building static library archive lib.a}])
    end
  end

  context "SharedLibrary builder" do
    it "allows explicitly specifying SHLD construction variable value" do
      test_dir("shared_library")

      result = run_rscons(args: %w[-f shared_library_set_shld.rb])
      expect(result.stderr).to eq ""
      slines = lines(result.stdout)
      if RUBY_PLATFORM =~ /mingw|msys/
        verify_lines(slines, [%r{Linking mine.dll}])
      else
        verify_lines(slines, [%r{Linking libmine.so}])
      end
    end

    it "allows passing object files as sources" do
      test_dir "shared_library"
      result = run_rscons(args: %w[-f shared_library_from_object.rb])
      expect(result.stderr).to eq ""
      expect(File.exist?("one.c.o"))
    end
  end

  context "Size builder" do
    it "generates a size file" do
      test_dir "simple"

      result = run_rscons(args: %w[-f size.rb])
      verify_lines(lines(result.stdout), [
        /Linking .*simple\.exe/,
        /Size .*simple\.exe .*simple\.size/,
      ])
      expect(File.exist?("simple.exe")).to be_truthy
      expect(File.exist?("simple.size")).to be_truthy
      expect(File.read("simple.size")).to match /text.*data/i
    end
  end

  context "multi-threading" do
    it "waits for subcommands in threads for builders that support threaded commands" do
      test_dir("simple")
      start_time = Time.new
      result = run_rscons(args: %w[-f threading.rb -j 4])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{ThreadedTestBuilder a},
        %r{ThreadedTestBuilder b},
        %r{ThreadedTestBuilder c},
        %r{NonThreadedTestBuilder d},
      ])
      elapsed = Time.new - start_time
      expect(elapsed).to be < 4
    end

    it "allows the user to specify that a target be built after another" do
      test_dir("custom_builder")
      result = run_rscons(args: %w[-f build_after.rb -j 4])
      expect(result.stderr).to eq ""
    end

    it "allows the user to specify side-effect files produced by another builder with Builder#produces" do
      test_dir("custom_builder")
      result = run_rscons(args: %w[-f produces.rb -j 4])
      expect(result.stderr).to eq ""
      expect(File.exist?("copy_inc.h")).to be_truthy
    end

    it "allows the user to specify side-effect files produced by another builder with Environment#produces" do
      test_dir("custom_builder")
      result = run_rscons(args: %w[-f produces_env.rb -j 4])
      expect(result.stderr).to eq ""
      expect(File.exist?("copy_inc.h")).to be_truthy
    end
  end

  context "CLI" do
    it "shows the version number and exits with --version argument" do
      test_dir("simple")
      result = run_rscons(args: %w[--version])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /version #{Rscons::VERSION}/
    end

    it "shows CLI help and exits with --help argument" do
      test_dir("simple")
      result = run_rscons(args: %w[--help])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /Usage:/
    end

    it "prints an error and exits with an error status when a default Rsconscript cannot be found" do
      test_dir("simple")
      FileUtils.rm_f("Rsconscript")
      result = run_rscons
      expect(result.stderr).to match /Could not find the Rsconscript to execute/
      expect(result.status).to_not eq 0
    end

    it "prints an error and exits with an error status when the given Rsconscript cannot be read" do
      test_dir("simple")
      result = run_rscons(args: %w[-f nonexistent])
      expect(result.stderr).to match /Cannot read nonexistent/
      expect(result.status).to_not eq 0
    end

    it "outputs an error for an unknown task" do
      test_dir "simple"
      result = run_rscons(args: "unknownop")
      expect(result.stderr).to match /Task 'unknownop' not found/
      expect(result.status).to_not eq 0
    end

    it "displays usage and error message without a backtrace for an invalid CLI option" do
      test_dir "simple"
      result = run_rscons(args: %w[--xyz])
      expect(result.stderr).to_not match /Traceback/
      expect(result.stderr).to match /invalid option.*--xyz/
      expect(result.stderr).to match /Usage:/
      expect(result.status).to_not eq 0
    end

    it "displays usage and error message without a backtrace for an invalid CLI option to a valid subcommand" do
      test_dir "simple"
      result = run_rscons(args: %w[configure --xyz])
      expect(result.stderr).to_not match /Traceback/
      expect(result.stderr).to match /Unknown parameter "xyz" for task configure/
      expect(result.status).to_not eq 0
    end
  end

  context "configure task" do
    it "does not print configuring messages when no configure block and configure task not called" do
      test_dir "configure"
      result = run_rscons(args: %w[-f no_configure_output.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout.chomp).to eq "default"
    end

    it "raises a method not found error for configure methods called outside a configure block" do
      test_dir "configure"
      result = run_rscons(args: %w[-f scope.rb])
      expect(result.stderr).to match /NoMethodError/
      expect(result.status).to_not eq 0
    end

    it "only runs the configure operation once" do
      test_dir "configure"

      result = run_rscons(args: %w[-f configure_with_top_level_env.rb configure])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to_not match %r{Configuring project.*Configuring project}m
    end

    it "loads configure parameters before invoking configure" do
      test_dir "configure"

      result = run_rscons(args: %w[-f configure_with_top_level_env.rb configure --prefix=/yodabob])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match "Prefix is /yodabob"
    end

    it "does not configure for distclean operation" do
      test_dir "configure"

      result = run_rscons(args: %w[-f configure_with_top_level_env.rb distclean])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to_not match %r{Configuring project}
    end

    it "does not configure for clean operation" do
      test_dir "configure"

      result = run_rscons(args: %w[-f configure_with_top_level_env.rb clean])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to_not match %r{Configuring project}
    end

    it "does not configure for uninstall operation" do
      test_dir "configure"

      result = run_rscons(args: %w[-f configure_with_top_level_env.rb uninstall])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to_not match %r{Configuring project}
    end

    it "automatically runs the configure task if the project is not yet configured in the given build directory" do
      test_dir "configure"

      result = run_rscons(args: %w[-f check_c_compiler.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /Checking for C compiler\.\.\./
      expect(Dir.exist?("build/_configure")).to be_truthy

      result = run_rscons(args: %w[-f check_c_compiler.rb --build=bb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /Checking for C compiler\.\.\./
      expect(Dir.exist?("bb/_configure")).to be_truthy
    end

    it "applies the configured settings to top-level created environments" do
      test_dir "configure"

      result = run_rscons(args: %w[-f check_c_compiler_non_default.rb -v])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /Checking for C compiler\.\.\./
      expect(result.stdout).to match /clang.*simple\.exe/
    end

    context "check_c_compiler" do
      {"check_c_compiler.rb" => "when no arguments are given",
       "check_c_compiler_find_first.rb" => "when arguments are given"}.each_pair do |rsconscript, desc|
        context desc do
          it "finds the first listed C compiler" do
            test_dir "configure"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect(result.stderr).to eq ""
            expect(result.status).to eq 0
            expect(result.stdout).to match /Checking for C compiler\.\.\. gcc/
          end

          it "finds the second listed C compiler" do
            test_dir "configure"
            create_exe "gcc", "exit 1"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect(result.stderr).to eq ""
            expect(result.status).to eq 0
            expect(result.stdout).to match /Checking for C compiler\.\.\. clang/
          end

          it "fails to configure when it cannot find a C compiler" do
            test_dir "configure"
            create_exe "gcc", "exit 1"
            create_exe "clang", "exit 1"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect(result.stderr).to match %r{Configuration failed; log file written to build/_configure/config.log}
            expect(result.status).to_not eq 0
            expect(result.stdout).to match /Checking for C compiler\.\.\. not found \(checked gcc, clang\)/
          end
        end
      end

      it "respects use flag" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_c_compiler_use.rb -v])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match %r{\bgcc .*/t1/}
        expect(result.stdout).to_not match %r{\bclang .*/t1/}
        expect(result.stdout).to match %r{\bclang .*/t2/}
        expect(result.stdout).to_not match %r{\bgcc .*/t2/}
      end

      it "successfully tests a compiler with an unknown name" do
        test_dir "configure"
        create_exe "mycompiler", %[exec gcc "$@"]
        result = run_rscons(args: %w[-f check_c_compiler_custom.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for C compiler\.\.\. mycompiler/
      end
    end

    context "check_cxx_compiler" do
      {"check_cxx_compiler.rb" => "when no arguments are given",
       "check_cxx_compiler_find_first.rb" => "when arguments are given"}.each_pair do |rsconscript, desc|
        context desc do
          it "finds the first listed C++ compiler" do
            test_dir "configure"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect(result.stderr).to eq ""
            expect(result.status).to eq 0
            expect(result.stdout).to match /Checking for C\+\+ compiler\.\.\. g\+\+/
          end

          it "finds the second listed C++ compiler" do
            test_dir "configure"
            create_exe "g++", "exit 1"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect(result.stderr).to eq ""
            expect(result.status).to eq 0
            expect(result.stdout).to match /Checking for C\+\+ compiler\.\.\. clang\+\+/
          end

          it "fails to configure when it cannot find a C++ compiler" do
            test_dir "configure"
            create_exe "g++", "exit 1"
            create_exe "clang++", "exit 1"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect(result.stderr).to match %r{Configuration failed; log file written to build/_configure/config.log}
            expect(result.status).to_not eq 0
            expect(result.stdout).to match /Checking for C\+\+ compiler\.\.\. not found \(checked g\+\+, clang\+\+\)/
          end
        end
      end

      it "respects use flag" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_cxx_compiler_use.rb -v])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match %r{\bg\+\+ .*/t1/}
        expect(result.stdout).to_not match %r{\bclang\+\+ .*/t1/}
        expect(result.stdout).to match %r{\bclang\+\+ .*/t2/}
        expect(result.stdout).to_not match %r{\bg\+\+ .*/t2/}
      end

      it "successfully tests a compiler with an unknown name" do
        test_dir "configure"
        create_exe "mycompiler", %[exec clang++ "$@"]
        result = run_rscons(args: %w[-f check_cxx_compiler_custom.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for C\+\+ compiler\.\.\. mycompiler/
      end
    end

    context "check_d_compiler" do
      {"check_d_compiler.rb" => "when no arguments are given",
       "check_d_compiler_find_first.rb" => "when arguments are given"}.each_pair do |rsconscript, desc|
        context desc do
          unless RUBY_PLATFORM =~ /mingw|msys|darwin/
            it "finds the first listed D compiler" do
              test_dir "configure"
              result = run_rscons(args: %W[-f #{rsconscript} configure])
              expect(result.stderr).to eq ""
              expect(result.status).to eq 0
              expect(result.stdout).to match /Checking for D compiler\.\.\. gdc/
            end
          end

          it "finds the second listed D compiler" do
            test_dir "configure"
            create_exe "gdc", "exit 1"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect(result.stderr).to eq ""
            expect(result.status).to eq 0
            expect(result.stdout).to match /Checking for D compiler\.\.\. ldc2/
          end

          it "fails to configure when it cannot find a D compiler" do
            test_dir "configure"
            create_exe "gdc", "exit 1"
            create_exe "ldc2", "exit 1"
            create_exe "ldc", "exit 1"
            result = run_rscons(args: %W[-f #{rsconscript} configure])
            expect(result.stderr).to match %r{Configuration failed; log file written to build/_configure/config.log}
            expect(result.status).to_not eq 0
            expect(result.stdout).to match /Checking for D compiler\.\.\. not found \(checked gdc, ldc2, ldc\)/
          end
        end
      end

      unless RUBY_PLATFORM =~ /mingw|msys|darwin/
        it "respects use flag" do
          test_dir "configure"
          result = run_rscons(args: %w[-f check_d_compiler_use.rb -v])
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to match %r{\bgdc .*/t1/}
          expect(result.stdout).to_not match %r{\bldc2 .*/t1/}
          expect(result.stdout).to match %r{\bldc2 .*/t2/}
          expect(result.stdout).to_not match %r{\bgdc .*/t2/}
        end

        it "successfully tests a compiler with an unknown name that uses gdc-compatible options" do
          test_dir "configure"
          create_exe "mycompiler", %[exec gdc "$@"]
          result = run_rscons(args: %w[-f check_d_compiler_custom.rb configure])
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to match /Checking for D compiler\.\.\. mycompiler/
        end
      end

      it "successfully tests a compiler with an unknown name that uses ldc2-compatible options" do
        test_dir "configure"
        create_exe "mycompiler", %[exec ldc2 "$@"]
        result = run_rscons(args: %w[-f check_d_compiler_custom.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for D compiler\.\.\. mycompiler/
      end
    end

    context "check_c_header" do
      it "succeeds when the requested header is found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_c_header_success.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for C header 'string\.h'... found/
      end

      it "fails when the requested header is not found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_c_header_failure.rb configure])
        expect(result.stderr).to match /Configuration failed/
        expect(result.status).to_not eq 0
        expect(result.stdout).to match /Checking for C header 'not___found\.h'... not found/
      end

      it "succeeds when the requested header is not found but :fail is set to false" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_c_header_no_fail.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for C header 'not___found\.h'... not found/
      end

      it "sets the specified define when the header is found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_c_header_success_set_define.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for C header 'string\.h'... found/
        result = run_rscons(args: %w[-f check_c_header_success_set_define.rb])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /-DHAVE_STRING_H/
      end

      it "does not set the specified define when the header is not found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_c_header_no_fail_set_define.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for C header 'not___found\.h'... not found/
        result = run_rscons(args: %w[-f check_c_header_no_fail_set_define.rb])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to_not match /-DHAVE_/
      end

      it "modifies CPPPATH based on check_cpppath" do
        test_dir "configure"
        FileUtils.mkdir_p("usr1")
        FileUtils.mkdir_p("usr2")
        File.open("usr2/frobulous.h", "wb") do |fh|
          fh.puts("#define FOO 42")
        end
        result = run_rscons(args: %w[-f check_c_header_cpppath.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        result = run_rscons(args: %w[-f check_c_header_cpppath.rb -v])
        expect(result.stdout).to_not match %r{-I./usr1}
        expect(result.stdout).to match %r{-I./usr2}
      end
    end

    context "check_cxx_header" do
      it "succeeds when the requested header is found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_cxx_header_success.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for C\+\+ header 'string\.h'... found/
      end

      it "fails when the requested header is not found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_cxx_header_failure.rb configure])
        expect(result.stderr).to match /Configuration failed/
        expect(result.status).to_not eq 0
        expect(result.stdout).to match /Checking for C\+\+ header 'not___found\.h'... not found/
      end

      it "succeeds when the requested header is not found but :fail is set to false" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_cxx_header_no_fail.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for C\+\+ header 'not___found\.h'... not found/
      end

      it "modifies CPPPATH based on check_cpppath" do
        test_dir "configure"
        FileUtils.mkdir_p("usr1")
        FileUtils.mkdir_p("usr2")
        File.open("usr2/frobulous.h", "wb") do |fh|
          fh.puts("#define FOO 42")
        end
        result = run_rscons(args: %w[-f check_cxx_header_cpppath.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        result = run_rscons(args: %w[-f check_cxx_header_cpppath.rb -v])
        expect(result.stdout).to_not match %r{-I./usr1}
        expect(result.stdout).to match %r{-I./usr2}
      end
    end

    context "check_d_import" do
      it "succeeds when the requested import is found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_d_import_success.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for D import 'std\.stdio'... found/
      end

      it "fails when the requested import is not found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_d_import_failure.rb configure])
        expect(result.stderr).to match /Configuration failed/
        expect(result.status).to_not eq 0
        expect(result.stdout).to match /Checking for D import 'not\.found'... not found/
      end

      it "succeeds when the requested import is not found but :fail is set to false" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_d_import_no_fail.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for D import 'not\.found'... not found/
      end

      it "modifies D_IMPORT_PATH based on check_d_import_path" do
        test_dir "configure"
        FileUtils.mkdir_p("usr1")
        FileUtils.mkdir_p("usr2")
        File.open("usr2/frobulous.d", "wb") do |fh|
          fh.puts("int foo = 42;")
        end
        result = run_rscons(args: %w[-f check_d_import_d_import_path.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        result = run_rscons(args: %w[-f check_d_import_d_import_path.rb -v])
        expect(result.stdout).to_not match %r{-I./usr1}
        expect(result.stdout).to match %r{-I./usr2}
      end
    end

    context "check_lib" do
      it "succeeds when the requested library is found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_lib_success.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for library 'm'... found/
      end

      it "fails when the requested library is not found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_lib_failure.rb configure])
        expect(result.stderr).to match /Configuration failed/
        expect(result.status).to_not eq 0
        expect(result.stdout).to match /Checking for library 'mfoofoo'... not found/
      end

      it "succeeds when the requested library is not found but :fail is set to false" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_lib_no_fail.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for library 'mfoofoo'... not found/
      end

      it "links against the checked library by default" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_lib_success.rb])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for library 'm'... found/
        expect(result.stdout).to match /gcc.*-lm/
      end

      it "does not link against the checked library by default if :use is specified" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_lib_use.rb])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for library 'm'... found/
        expect(result.stdout).to_not match /gcc.*test1.*-lm/
        expect(result.stdout).to match /gcc.*test2.*-lm/
      end

      it "does not link against the checked library if :use is set to false" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_lib_use_false.rb])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for library 'm'... found/
        expect(result.stdout).to_not match /-lm/
      end

      it "finds the requested library with only ldc compiler" do
        test_dir "configure"
        create_exe "gcc", "exit 1"
        create_exe "clang", "exit 1"
        create_exe "gcc++", "exit 1"
        create_exe "clang++", "exit 1"
        result = run_rscons(args: %w[-f check_lib_with_ldc.rb])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for library 'z'... found/
      end

      it "modifies LIBPATH based on check_libpath" do
        test_dir "configure"
        FileUtils.mkdir_p("usr1")
        FileUtils.mkdir_p("usr2")
        result = run_rscons(args: %w[-f check_lib_libpath1.rb])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        result = run_rscons(args: %w[-f check_lib_libpath2.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        result = run_rscons(args: %w[-f check_lib_libpath2.rb])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match %r{-L\./usr2}
        expect(result.stdout).to_not match %r{-L\./usr1}
      end
    end

    context "check_program" do
      it "succeeds when the requested program is found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_program_success.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for program 'find'... .*find/
      end

      context "with non-existent PATH entries" do
        it "succeeds when the requested program is found" do
          test_dir "configure"
          result = run_rscons(args: %w[-f check_program_success.rb configure], path: "/foo/bar")
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to match /Checking for program 'find'... .*find/
        end
      end

      it "fails when the requested program is not found" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_program_failure.rb configure])
        expect(result.stderr).to match /Configuration failed/
        expect(result.status).to_not eq 0
        expect(result.stdout).to match /Checking for program 'program-that-is-not-found'... not found/
      end

      it "succeeds when the requested program is not found but :fail is set to false" do
        test_dir "configure"
        result = run_rscons(args: %w[-f check_program_no_fail.rb configure])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
        expect(result.stdout).to match /Checking for program 'program-that-is-not-found'... not found/
      end
    end

    context "check_cfg" do
      context "when passed a package" do
        it "stores flags and uses them during a build" do
          test_dir "configure"
          create_exe "pkg-config", "echo '-DMYPACKAGE'"
          result = run_rscons(args: %w[-f check_cfg_package.rb configure])
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to match /Checking for package 'mypackage'\.\.\. found/
          result = run_rscons(args: %w[-f check_cfg_package.rb])
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to match /gcc.*-o.*\.o.*-DMYPACKAGE/
        end

        it "fails when the configure program given does not exist" do
          test_dir "configure"
          result = run_rscons(args: %w[-f check_cfg.rb configure])
          expect(result.stderr).to match /Configuration failed/
          expect(result.status).to_not eq 0
          expect(result.stdout).to match /Checking 'my-config'\.\.\. not found/
        end

        it "does not use the flags found by default if :use is specified" do
          test_dir "configure"
          create_exe "pkg-config", "echo '-DMYPACKAGE'"
          result = run_rscons(args: %w[-f check_cfg_use.rb configure])
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to match /Checking for package 'mypackage'\.\.\. found/
          result = run_rscons(args: %w[-f check_cfg_use.rb])
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to_not match /gcc.*-o.*myconfigtest1.*-DMYPACKAGE/
          expect(result.stdout).to match /gcc.*-o.*myconfigtest2.*-DMYPACKAGE/
        end

        it "indicates that pkg-config command cannot be found" do
          test_dir "configure"
          result = run_rscons(args: %w[-f check_cfg_no_pkg_config.rb configure])
          expect(result.stderr).to match /Error: executable 'pkg-config' not found/
          expect(result.status).to_not eq 0
        end
      end

      context "when passed a program" do
        it "stores flags and uses them during a build" do
          test_dir "configure"
          create_exe "my-config", "echo '-DMYCONFIG -lm'"
          result = run_rscons(args: %w[-f check_cfg.rb configure])
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to match /Checking 'my-config'\.\.\. found/
          result = run_rscons(args: %w[-f check_cfg.rb])
          expect(result.stderr).to eq ""
          expect(result.status).to eq 0
          expect(result.stdout).to match /gcc.*-o.*\.o.*-DMYCONFIG/
          expect(result.stdout).to match /gcc.*-o myconfigtest.*-lm/
        end
      end
    end

    context "custom_check" do
      context "when running a test command" do
        context "when executing the command fails" do
          context "when failures are fatal" do
            it "fails configuration with the correct error message" do
              test_dir "configure"
              create_exe "grep", "exit 4"
              result = run_rscons(args: %w[-f custom_config_check.rb configure])
              expect(result.stderr).to match /Configuration failed/
              expect(result.stdout).to match /Checking 'grep' version\.\.\. error executing grep/
              expect(result.status).to_not eq 0
            end
          end

          context "when the custom logic indicates a failure" do
            it "fails configuration with the correct error message" do
              test_dir "configure"
              create_exe "grep", "echo 'grep (GNU grep) 1.1'"
              result = run_rscons(args: %w[-f custom_config_check.rb configure])
              expect(result.stderr).to match /Configuration failed/
              expect(result.stdout).to match /Checking 'grep' version\.\.\. too old!/
              expect(result.status).to_not eq 0
            end
          end
        end

        context "when failures are not fatal" do
          context "when the custom logic indicates a failure" do
            it "displays the correct message and does not fail configuration" do
              test_dir "configure"
              create_exe "grep", "echo 'grep (GNU grep) 2.1'"
              result = run_rscons(args: %w[-f custom_config_check.rb configure])
              expect(result.stderr).to eq ""
              expect(result.stdout).to match /Checking 'grep' version\.\.\. we'll work with it but you should upgrade/
              expect(result.status).to eq 0
              result = run_rscons(args: %w[-f custom_config_check.rb])
              expect(result.stderr).to eq ""
              expect(result.stdout).to match /GREP_WORKAROUND/
              expect(result.status).to eq 0
            end
          end
        end

        context "when the custom logic indicates success" do
          it "passes configuration with the correct message" do
            test_dir "configure"
            create_exe "grep", "echo 'grep (GNU grep) 3.0'"
            result = run_rscons(args: %w[-f custom_config_check.rb configure])
            expect(result.stderr).to eq ""
            expect(result.stdout).to match /Checking 'grep' version\.\.\. good!/
            expect(result.status).to eq 0
            result = run_rscons(args: %w[-f custom_config_check.rb])
            expect(result.stderr).to eq ""
            expect(result.stdout).to match /GREP_FULL/
            expect(result.status).to eq 0
          end
        end

        it "allows passing standard input data to the executed command" do
          test_dir "configure"
          result = run_rscons(args: %w[-f custom_config_check.rb configure])
          expect(result.stderr).to eq ""
          expect(result.stdout).to match /Checking sed -E flag\.\.\. good/
          expect(result.status).to eq 0
        end
      end
    end

    context "on_fail option" do
      it "prints on_fail messages and calls on_fail procs on failure" do
        test_dir "configure"
        result = run_rscons(args: %w[-f on_fail.rb configure])
        expect(result.status).to_not eq 0
        expect(result.stdout).to match /Install the foo123 package/
        expect(result.stdout).to match /Install the foo123cxx package/
      end
    end

    it "does everything" do
      test_dir "configure"
      create_exe "pkg-config", "echo '-DMYPACKAGE'"
      result = run_rscons(args: %w[-f everything.rb --build=bb configure --prefix=/my/prefix])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /Configuring configure test\.\.\./
      expect(result.stdout).to match %r{Setting prefix\.\.\. /my/prefix}
      expect(result.stdout).to match /Checking for C compiler\.\.\. gcc/
      expect(result.stdout).to match /Checking for C\+\+ compiler\.\.\. g\+\+/
      expect(result.stdout).to match /Checking for D compiler\.\.\. (gdc|ldc2)/
      expect(result.stdout).to match /Checking for package 'mypackage'\.\.\. found/
      expect(result.stdout).to match /Checking for C header 'stdio.h'\.\.\. found/
      expect(result.stdout).to match /Checking for C\+\+ header 'iostream'\.\.\. found/
      expect(result.stdout).to match /Checking for D import 'std.stdio'\.\.\. found/
      expect(result.stdout).to match /Checking for library 'm'\.\.\. found/
      expect(result.stdout).to match /Checking for program 'ls'\.\.\. .*ls/
      expect(Dir.exist?("build")).to be_falsey
      expect(Dir.exist?("bb/_configure")).to be_truthy
    end

    it "aggregates multiple set_define's" do
      test_dir "configure"
      result = run_rscons(args: %w[-f multiple_set_define.rb configure])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      result = run_rscons(args: %w[-f multiple_set_define.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /gcc.*-o.*\.o.*-DHAVE_MATH_H\s.*-DHAVE_STDIO_H/
    end

    it "exits with an error if the project is not configured and a build is requested and autoconf is false" do
      test_dir "configure"
      result = run_rscons(args: %w[-f autoconf_false.rb])
      expect(result.stderr).to match /Project must be configured before creating an Environment/
      expect(result.status).to_not eq 0
    end

    it "exits with an error code and message if configuration fails during autoconf" do
      test_dir "configure"
      result = run_rscons(args: %w[-f autoconf_fail.rb])
      expect(result.stdout).to match /Checking for C compiler\.\.\. not found/
      expect(result.status).to_not eq 0
      expect(result.stderr).to_not match /from\s/
      expect(lines(result.stderr).last).to match /Configuration failed/
    end

    it "does not rebuild after building with auto-configuration" do
      test_dir "configure"
      result = run_rscons(args: %w[-f autoconf_rebuild.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("simple.exe")).to be_truthy
      result = run_rscons(args: %w[-f autoconf_rebuild.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to eq ""
    end
  end

  context "distclean" do
    it "removes built files and the build directory" do
      test_dir "simple"
      result = run_rscons(args: %w[-f distclean.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("simple.o")).to be_truthy
      expect(File.exist?("build")).to be_truthy
      result = run_rscons(args: %w[-f distclean.rb distclean])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("simple.o")).to be_falsey
      expect(File.exist?("build")).to be_falsey
    end
  end

  context "verbose option" do
    it "does not echo commands when verbose options not given" do
      test_dir('simple')
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(result.stdout).to match /Compiling.*simple\.c/
    end

    it "echoes commands by default with -v" do
      test_dir('simple')
      result = run_rscons(args: %w[-v])
      expect(result.stderr).to eq ""
      expect(result.stdout).to match /gcc.*-o.*simple/
    end

    it "echoes commands by default with --verbose" do
      test_dir('simple')
      result = run_rscons(args: %w[--verbose])
      expect(result.stderr).to eq ""
      expect(result.stdout).to match /gcc.*-o.*simple/
    end
  end

  context "direct mode" do
    it "allows calling Program builder in direct mode and passes all sources to the C compiler" do
      test_dir("direct")

      result = run_rscons(args: %w[-f c_program.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to match %r{Compiling/Linking}
      expect(File.exist?("test.exe")).to be_truthy
      expect(`./test.exe`).to match /three/

      result = run_rscons(args: %w[-f c_program.rb])
      expect(result.stdout).to eq ""

      three_h = File.read("three.h", mode: "rb")
      File.open("three.h", "wb") do |fh|
        fh.write(three_h)
        fh.puts("#define FOO 42")
      end
      result = run_rscons(args: %w[-f c_program.rb])
      expect(result.stdout).to match %r{Compiling/Linking}
    end

    it "allows calling SharedLibrary builder in direct mode and passes all sources to the C compiler" do
      test_dir("direct")

      result = run_rscons(args: %w[-f c_shared_library.rb])
      expect(result.stderr).to eq ""
      expect(result.stdout).to match %r{Compiling/Linking}
      expect(File.exist?("test.exe")).to be_truthy
      ld_library_path_prefix = (RUBY_PLATFORM =~ /mingw|msys/ ? "" : "LD_LIBRARY_PATH=. ")
      expect(`#{ld_library_path_prefix}./test.exe`).to match /three/

      result = run_rscons(args: %w[-f c_shared_library.rb])
      expect(result.stdout).to eq ""

      three_h = File.read("three.h", mode: "rb")
      File.open("three.h", "wb") do |fh|
        fh.write(three_h)
        fh.puts("#define FOO 42")
      end
      result = run_rscons(args: %w[-f c_shared_library.rb])
      expect(result.stdout).to match %r{Compiling/Linking}
    end
  end

  context "install task" do
    it "invokes the configure task if the project is not yet configured" do
      test_dir "typical"

      result = run_rscons(args: %w[-f install.rb install])
      expect(result.stdout).to match /Configuring install_test/
    end

    it "invokes a build dependency" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""
        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Compiling/
        expect(result.stdout).to match /Linking/
      end
    end

    it "installs the requested directories and files" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Creating directory/
        expect(result.stdout).to match /Install install.rb =>/
        expect(result.stdout).to match /Install src =>/
        expect(Dir.entries(prefix)).to match_array %w[. .. bin src share mult]
        expect(File.directory?("#{prefix}/bin")).to be_truthy
        expect(File.directory?("#{prefix}/src")).to be_truthy
        expect(File.directory?("#{prefix}/share")).to be_truthy
        expect(File.exist?("#{prefix}/bin/program.exe")).to be_truthy
        expect(File.exist?("#{prefix}/src/one/one.c")).to be_truthy
        expect(File.exist?("#{prefix}/share/proj/install.rb")).to be_truthy
        expect(File.exist?("#{prefix}/mult/install.rb")).to be_truthy
        expect(File.exist?("#{prefix}/mult/copy.rb")).to be_truthy

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""
        expect(result.stdout).to eq ""
      end
    end

    it "does not install when only a build is performed" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb])
        expect(result.stderr).to eq ""
        expect(result.stdout).to_not match /Install/
        expect(Dir.entries(prefix)).to match_array %w[. ..]

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match /Install/
      end
    end
  end

  context "uninstall task" do
    it "removes installed files but not built files" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""
        expect(File.exist?("#{prefix}/bin/program.exe")).to be_truthy
        expect(File.exist?("build/o/src/one/one.c.o")).to be_truthy

        result = run_rscons(args: %w[-f install.rb uninstall])
        expect(result.stderr).to eq ""
        expect(result.stdout).to_not match /Removing/
        expect(File.exist?("#{prefix}/bin/program.exe")).to be_falsey
        expect(File.exist?("build/o/src/one/one.c.o")).to be_truthy
        expect(Dir.entries(prefix)).to match_array %w[. ..]
      end
    end

    it "prints removed files and directories when running verbosely" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb -v uninstall])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match %r{Removing #{prefix}/bin/program.exe}
        expect(File.exist?("#{prefix}/bin/program.exe")).to be_falsey
        expect(Dir.entries(prefix)).to match_array %w[. ..]
      end
    end

    it "removes cache entries when uninstalling" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb -v uninstall])
        expect(result.stderr).to eq ""
        expect(result.stdout).to match %r{Removing #{prefix}/bin/program.exe}
        expect(File.exist?("#{prefix}/bin/program.exe")).to be_falsey
        expect(Dir.entries(prefix)).to match_array %w[. ..]

        FileUtils.mkdir_p("#{prefix}/bin")
        File.open("#{prefix}/bin/program.exe", "w") {|fh| fh.write("hi")}
        result = run_rscons(args: %w[-f install.rb -v uninstall])
        expect(result.stderr).to eq ""
        expect(result.stdout).to_not match /Removing/
      end
    end
  end

  context "build progress" do
    it "does not include install targets in build progress when not doing an install" do
      test_dir "typical"

      result = run_rscons(args: %w[-f install.rb])
      expect(result.stderr).to eq ""
      verify_lines(lines(result.stdout), [
        %r{\[1/3\] Compiling},
        %r{\[2/3\] Compiling},
        %r{\[3/3\] Linking},
      ])
    end

    it "counts install task targets separately from build task targets" do
      test_dir "typical"

      Dir.mktmpdir do |prefix|
        result = run_rscons(args: %W[-f install.rb configure --prefix=#{prefix}])
        expect(result.stderr).to eq ""

        result = run_rscons(args: %w[-f install.rb install])
        expect(result.stderr).to eq ""
        verify_lines(lines(result.stdout), [
          %r{\[1/3\] Compiling},
          %r{\[2/3\] Compiling},
          %r{\[\d/6\] Install},
        ])
      end
    end

    it "separates build steps from each environment when showing build progress" do
      test_dir "typical"

      result = run_rscons(args: %w[-f multiple_environments.rb])
      expect(result.stderr).to eq ""
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
      it "executes the subsidiary script from configure block" do
        test_dir "subsidiary"

        result = run_rscons(args: %w[configure])
        expect(result.stderr).to eq ""
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

      it "executes the subsidiary script from build block" do
        test_dir "subsidiary"

        result = run_rscons(args: %w[configure])
        expect(result.stderr).to eq ""
        result = run_rscons
        expect(result.stderr).to eq ""
        verify_lines(lines(result.stdout), [
          %r{sub Rsconscript2 build},
          %r{top build},
        ])
      end
    end

    context "with a directory specified" do
      it "executes the subsidiary script from configure block" do
        test_dir "subsidiary"

        result = run_rscons(args: %w[-f Rsconscript_dir configure])
        expect(result.stderr).to eq ""
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

      it "executes the subsidiary script from build block" do
        test_dir "subsidiary"

        result = run_rscons(args: %w[-f Rsconscript_dir configure])
        expect(result.stderr).to eq ""
        result = run_rscons(args: %w[-f Rsconscript_dir])
        expect(result.stderr).to eq ""
        verify_lines(lines(result.stdout), [
          %r{sub Rsconscript2 build},
          %r{top build},
        ])
      end
    end

    context "with a rscons binary in the subsidiary script directory" do
      it "executes rscons from the subsidiary script directory" do
        test_dir "subsidiary"

        File.binwrite("sub/rscons", <<EOF)
#!/usr/bin/env ruby
puts "sub rscons"
EOF
        FileUtils.chmod(0755, "sub/rscons")
        result = run_rscons(args: %w[configure])
        expect(result.stderr).to eq ""
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

    it "does not print entering/leaving directory messages when the subsidiary script is in the same directory" do
      test_dir "subsidiary"

      result = run_rscons(args: %w[-f Rsconscript_samedir configure])
      expect(result.stderr).to eq ""
      result = run_rscons(args: %w[-f Rsconscript_samedir])
      expect(result.stderr).to eq ""
      expect(result.stdout).to_not match(%{(Entering|Leaving) directory})
      verify_lines(lines(result.stdout), [
        %r{second build},
        %r{top build},
      ])
    end

    it "terminates execution when a subsidiary script fails" do
      test_dir "subsidiary"

      result = run_rscons(args: %w[-f Rsconscript_fail configure])
      expect(result.stderr).to_not eq ""
      expect(result.status).to_not eq 0
      expect(result.stdout).to_not match /top configure/
    end

    it "does not pass RSCONS_BUILD_DIR to subsidiary scripts" do
      test_dir "subsidiary"
      passenv["RSCONS_BUILD_DIR"] = "buildit"
      result = run_rscons(args: %w[configure])
      expect(result.stderr).to eq ""
      expect(Dir.exist?("build")).to be_falsey
      expect(Dir.exist?("buildit")).to be_truthy
      expect(Dir.exist?("sub/build")).to be_truthy
      expect(Dir.exist?("sub/buildit")).to be_falsey
    end
  end

  context "sh method" do
    it "executes the command given" do
      test_dir "typical"
      result = run_rscons(args: %w[-f sh.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      verify_lines(lines(result.stdout), [
        "hi  there",
        "1 2",
      ])
    end

    it "changes directory to execute the requested command" do
      test_dir "typical"
      result = run_rscons(args: %w[-f sh_chdir.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match %r{/src$}
    end

    it "prints the command when executing verbosely" do
      test_dir "typical"
      result = run_rscons(args: %w[-f sh.rb -v])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      verify_lines(lines(result.stdout), [
        %r{echo 'hi  there'},
        "hi  there",
        %r{echo  1  2},
        "1 2",
      ])
    end

    it "terminates execution on failure" do
      test_dir "typical"
      result = run_rscons(args: %w[-f sh_fail.rb])
      expect(result.stderr).to match /sh_fail\.rb:2:.*foobar42/
      expect(result.status).to_not eq 0
      expect(result.stdout).to_not match /continued/
    end

    it "continues execution on failure when :continue option is set" do
      test_dir "typical"
      result = run_rscons(args: %w[-f sh_fail_continue.rb])
      expect(result.stderr).to match /sh_fail_continue\.rb:2:.*foobar42/
      expect(result.status).to eq 0
      expect(result.stdout).to match /continued/
    end
  end

  context "FileUtils methods" do
    it "defines FileUtils methods to be available in the build script" do
      test_dir "typical"
      result = run_rscons(args: %w[-f fileutils_methods.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(Dir.exist?("foobar")).to be_truthy
      expect(Dir.exist?("foo")).to be_falsey
      expect(File.exist?("foobar/baz/b.txt")).to be_truthy
    end
  end

  it "executes the requested tasks in the requested order" do
    test_dir "tasks"
    result = run_rscons(args: %w[-f tasks.rb configure])
    result = run_rscons(args: %w[-f tasks.rb one three])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(result.stdout).to eq "one\nthree\n"
    result = run_rscons(args: %w[-f tasks.rb three one])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(result.stdout).to eq "three\none\n"
  end

  it "executes the task's dependencies before the requested task" do
    test_dir "tasks"
    result = run_rscons(args: %w[-f tasks.rb configure])
    result = run_rscons(args: %w[-f tasks.rb two])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(result.stdout).to eq "one\nthree\ntwo\n"
  end

  it "does not execute a task more than once" do
    test_dir "tasks"
    result = run_rscons(args: %w[-f tasks.rb configure])
    result = run_rscons(args: %w[-f tasks.rb one two three])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(result.stdout).to eq "one\nthree\ntwo\n"
  end

  it "passes task arguments" do
    test_dir "tasks"
    result = run_rscons(args: %w[-f tasks.rb configure])
    result = run_rscons(args: %w[-f tasks.rb four])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(result.stdout).to eq %[four\nmyparam:"defaultvalue"\nmyp2:nil\n]
    result = run_rscons(args: %w[-f tasks.rb four --myparam=cli-value --myp2 one])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(result.stdout).to eq %[four\nmyparam:"cli-value"\nmyp2:true\none\n]
  end

  it "allows accessing task arguments via Task#[]" do
    test_dir "tasks"
    result = run_rscons(args: %w[-f tasks.rb configure])
    result = run_rscons(args: %w[-f tasks.rb five])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(result.stdout).to match /four myparam value is defaultvalue/
    result = run_rscons(args: %w[-f tasks.rb four --myparam=v42 five])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(result.stdout).to match /four myparam value is v42/
  end

  it "exits with an error when attempting to get a nonexistent parameter value" do
    test_dir "tasks"
    result = run_rscons(args: %w[-f tasks.rb configure])
    result = run_rscons(args: %w[-f tasks.rb six])
    expect(result.stderr).to match /Could not find parameter 'nope'/
    expect(result.status).to_not eq 0
  end

  context "with -T flag" do
    it "displays tasks and their parameters" do
      test_dir "tasks"
      result = run_rscons(args: %w[-f tasks.rb -T])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      verify_lines(lines(result.stdout), [
        "Tasks:",
        /\bthree\b\s+Task three/,
        /\bfour\b\s+Task four/,
        /--myparam=MYPARAM\s+My special parameter/,
        /--myp2\s+My parameter 2/,
      ])
      expect(result.stdout).to_not match /^\s*one\b/
      expect(result.stdout).to_not match /^\s*two\b/
    end

    context "with -A flag" do
      it "displays all tasks and their parameters" do
        test_dir "tasks"
        result = run_rscons(args: %w[-f tasks.rb -AT])
        expect(result.stderr).to eq ""
        expect(result.status).to eq 0
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
    it "downloads the specified file unless it already exists with the expected checksum" do
      test_dir "typical"
      result = run_rscons(args: %w[-f download.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("rscons-2.3.0")).to be_truthy
    end

    it "downloads the specified file if no checksum is given" do
      test_dir "typical"
      result = run_rscons(args: %w[-f download.rb nochecksum])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("rscons-2.3.0")).to be_truthy
      expect(File.binread("rscons-2.3.0").size).to be > 100
    end

    it "exits with an error if the downloaded file checksum does not match the given checksum" do
      test_dir "typical"
      result = run_rscons(args: %w[-f download.rb badchecksum])
      expect(result.stderr).to match /Unexpected checksum on rscons-2.3.0/
      expect(result.status).to_not eq 0
    end

    it "exits with an error if the redirect limit is reached" do
      test_dir "typical"
      result = run_rscons(args: %w[-f download.rb redirectlimit])
      expect(result.stderr).to match /Redirect limit reached when downloading rscons-2.3.0/
      expect(result.status).to_not eq 0
    end

    it "exits with an error if the download results in an error" do
      test_dir "typical"
      result = run_rscons(args: %w[-f download.rb badurl])
      expect(result.stderr).to match /Error downloading rscons-2.3.0/
      expect(result.status).to_not eq 0
    end

    it "exits with an error if the download results in a socket error" do
      test_dir "typical"
      result = run_rscons(args: %w[-f download.rb badhost])
      expect(result.stderr).to match /Error downloading foo: .*ksfjlias/
      expect(result.status).to_not eq 0
    end
  end

  context "configure task parameters" do
    it "allows access to configure task parameters from another task" do
      test_dir "tasks"

      result = run_rscons(args: %w[-f configure_params.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /xyz: xyz/
      expect(result.stdout).to match /flag: nil/

      result = run_rscons(args: %w[-f configure_params.rb configure --with-xyz=foo --flag default])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /xyz: foo/
      expect(result.stdout).to match /flag: true/
    end

    it "stores configure task parameters in the cache for subsequent invocations" do
      test_dir "tasks"

      result = run_rscons(args: %w[-f configure_params.rb configure --with-xyz=foo --flag default])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /xyz: foo/
      expect(result.stdout).to match /flag: true/

      result = run_rscons(args: %w[-f configure_params.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match /xyz: foo/
      expect(result.stdout).to match /flag: true/
    end
  end

  context "variants" do
    it "appends variant names to environment names to form build directories" do
      test_dir "variants"
      result = run_rscons
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/prog-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-release/prog.exe")).to be_truthy
    end

    it "allows querying active variants and changing behavior" do
      test_dir "variants"
      result = run_rscons(args: %w[-v])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/prog-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-release/prog.exe")).to be_truthy
      expect(result.stdout).to match %r{gcc .*-o.*build/prog-debug/.*-DDEBUG}
      expect(result.stdout).to match %r{gcc .*-o.*build/prog-release/.*-DNDEBUG}
    end

    it "allows specifying a nil key for a variant" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f nil_key.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/prog-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog/prog.exe")).to be_truthy
      expect(result.stdout).to match %r{gcc .*-o.*build/prog-debug/.*-DDEBUG}
      expect(result.stdout).to match %r{gcc .*-o.*build/prog/.*-DNDEBUG}
    end

    it "allows multiple variant groups" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f multiple_groups.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/prog-kde-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-kde-release/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-gnome-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-gnome-release/prog.exe")).to be_truthy
      expect(result.stdout).to match %r{gcc .*-o.*build/prog-kde-debug/.*-DKDE.*-DDEBUG}
      expect(result.stdout).to match %r{gcc .*-o.*build/prog-kde-release/.*-DKDE.*-DNDEBUG}
      expect(result.stdout).to match %r{gcc .*-o.*build/prog-gnome-debug/.*-DGNOME.*-DDEBUG}
      expect(result.stdout).to match %r{gcc .*-o.*build/prog-gnome-release/.*-DGNOME.*-DNDEBUG}
    end

    it "raises an error when with_variants is called within another with_variants block" do
      test_dir "variants"
      result = run_rscons(args: %w[-f error_nested_with_variants.rb])
      expect(result.stderr).to match %r{with_variants cannot be called within another with_variants block}
      expect(result.status).to_not eq 0
    end

    it "raises an error when with_variants is called with no variants defined" do
      test_dir "variants"
      result = run_rscons(args: %w[-f error_with_variants_without_variants.rb])
      expect(result.stderr).to match %r{with_variants cannot be called with no variants defined}
      expect(result.status).to_not eq 0
    end

    it "allows specifying the exact enabled variants on the command line 1" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f multiple_groups.rb -e kde,debug])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/prog-kde-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-kde-release/prog.exe")).to be_falsey
      expect(File.exist?("build/prog-gnome-debug/prog.exe")).to be_falsey
      expect(File.exist?("build/prog-gnome-release/prog.exe")).to be_falsey
    end

    it "allows specifying the exact enabled variants on the command line 2" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f multiple_groups.rb -e kde,gnome,release])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/prog-kde-debug/prog.exe")).to be_falsey
      expect(File.exist?("build/prog-kde-release/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-gnome-debug/prog.exe")).to be_falsey
      expect(File.exist?("build/prog-gnome-release/prog.exe")).to be_truthy
    end

    it "allows disabling a single variant on the command line" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f multiple_groups.rb --variants=-kde])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/prog-kde-debug/prog.exe")).to be_falsey
      expect(File.exist?("build/prog-kde-release/prog.exe")).to be_falsey
      expect(File.exist?("build/prog-gnome-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-gnome-release/prog.exe")).to be_truthy
    end

    it "allows turning off variants by default" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f default.rb])
      expect(File.exist?("build/prog-debug/prog.exe")).to be_falsey
      expect(File.exist?("build/prog-release/prog.exe")).to be_truthy
    end

    it "allows turning on an off-by-default-variant from the command line" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f default.rb -e +debug])
      expect(File.exist?("build/prog-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-release/prog.exe")).to be_truthy
    end

    it "allows only turning on an off-by-default-variant from the command line" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f default.rb -e debug])
      expect(File.exist?("build/prog-debug/prog.exe")).to be_truthy
      expect(File.exist?("build/prog-release/prog.exe")).to be_falsey
    end

    it "exits with an error if no variant in a variant group is activated" do
      test_dir "variants"
      result = run_rscons(args: %w[-v -f multiple_groups.rb --variants=kde])
      expect(result.stderr).to match %r{No variants enabled for variant group}
      expect(result.status).to_not eq 0
    end

    it "allows querying if a variant is enabled" do
      test_dir "variants"

      result = run_rscons(args: %w[-f variant_enabled.rb configure])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match %r{one enabled}
      expect(result.stdout).to_not match %r{two enabled}
      expect(result.stdout).to_not match %r{three enabled}

      result = run_rscons(args: %w[-f variant_enabled.rb --variants=+two configure])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to match %r{one enabled}
      expect(result.stdout).to match %r{two enabled}
      expect(result.stdout).to_not match %r{three enabled}

      result = run_rscons(args: %w[-f variant_enabled.rb --variants=two configure])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(result.stdout).to_not match %r{one enabled}
      expect(result.stdout).to match %r{two enabled}
      expect(result.stdout).to_not match %r{three enabled}
    end

    it "shows available variants with -T" do
      test_dir "variants"

      result = run_rscons(args: %w[-f multiple_groups.rb -T])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      verify_lines(lines(result.stdout), [
        "Variant group 'desktop-environment':",
        "  kde (enabled)",
        "  gnome (enabled)",
        "Variant group 'debug':",
        "  debug (enabled)",
        "  release (enabled)",
      ])

      result = run_rscons(args: %w[-f multiple_groups.rb -e gnome,release configure])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      result = run_rscons(args: %w[-f multiple_groups.rb -T])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      verify_lines(lines(result.stdout), [
        "Variant group 'desktop-environment':",
        "  kde",
        "  gnome (enabled)",
        "Variant group 'debug':",
        "  debug",
        "  release (enabled)",
      ])
    end

    it "raises an error when an unnamed environment is created with multiple active variants" do
      test_dir "variants"
      result = run_rscons(args: %w[-f error_unnamed_environment.rb])
      expect(result.stderr).to match /Error: an Environment with active variants must be given a name/
      expect(result.status).to_not eq 0
    end
  end

  context "build_dir method" do
    it "returns the top-level build directory path 1" do
      test_dir "typical"
      result = run_rscons(args: %w[-f build_dir.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/a.file")).to be_truthy
    end

    it "returns the top-level build directory path 2" do
      test_dir "typical"
      result = run_rscons(args: %w[-f build_dir.rb -b bb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("bb/a.file")).to be_truthy
    end
  end

  if RUBY_PLATFORM =~ /linux/
    it "allows writing a binary to an environment's build directory with the same name as a top-level source folder" do
      test_dir "typical"
      result = run_rscons(args: %w[-f binary_matching_folder.rb])
      expect(result.stderr).to eq ""
      expect(result.status).to eq 0
      expect(File.exist?("build/src/src")).to be_truthy
    end
  end

  it "supports building LLVM assembly files with the Program builder" do
    test_dir "llvm"
    result = run_rscons
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(File.exist?("llvmtest.exe")).to be_truthy
    expect(`./llvmtest.exe`).to match /hello world/
  end

  it "supports building LLVM assembly files with the Program builder in direct mode" do
    test_dir "llvm"
    result = run_rscons(args: %w[-f direct.rb])
    expect(result.stderr).to eq ""
    expect(result.status).to eq 0
    expect(File.exist?("llvmtest.exe")).to be_truthy
    expect(`./llvmtest.exe`).to match /hello again/
  end

end
