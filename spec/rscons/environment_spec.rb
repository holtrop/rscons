module Rscons
  describe Environment do
    describe "#initialize" do
      it "adds the default builders when they are not excluded" do
        env = Environment.new
        env.builders.size.should be > 0
        env.builders.map {|name, builder| builder.is_a?(Builder)}.all?.should be_true
        env.builders.find {|name, builder| name == "Object"}.should_not be_nil
        env.builders.find {|name, builder| name == "Program"}.should_not be_nil
        env.builders.find {|name, builder| name == "Library"}.should_not be_nil
      end

      it "excludes the default builders with exclude_builders: :all" do
        env = Environment.new(exclude_builders: true)
        env.builders.size.should == 0
      end

      context "when a block is given" do
        it "yields self and invokes #process()" do
          env = Environment.new do |env|
            env.should_receive(:process)
          end
        end
      end
    end

    describe "#clone" do
      it 'should create unique copies of each construction variable' do
        env = Environment.new
        env["CPPPATH"] << "path1"
        env2 = env.clone
        env2["CPPPATH"] << "path2"
        env["CPPPATH"].should == ["path1"]
        env2["CPPPATH"].should == ["path1", "path2"]
      end

      it "supports nil, false, true, String, Symbol, Array, Hash, and Integer variables" do
        env = Environment.new
        env["nil"] = nil
        env["false"] = false
        env["true"] = true
        env["String"] = "String"
        env["Symbol"] = :Symbol
        env["Array"] = ["a", "b"]
        env["Hash"] = {"a" => "b"}
        env["Integer"] = 1234
        env2 = env.clone
        expect(env2["nil"]).to be_nil
        expect(env2["false"].object_id).to eq(false.object_id)
        expect(env2["true"].object_id).to eq(true.object_id)
        expect(env2["String"]).to eq("String")
        expect(env2["Symbol"]).to eq(:Symbol)
        expect(env2["Array"]).to eq(["a", "b"])
        expect(env2["Hash"]).to eq({"a" => "b"})
        expect(env2["Integer"]).to eq(1234)
      end

      context "when a block is given" do
        it "yields self and invokes #process()" do
          env = Environment.new
          env.clone do |env2|
            env2.should_receive(:process)
          end
        end
      end
    end

    describe "#add_builder" do
      it "adds the builder to the list of builders" do
        env = Environment.new(exclude_builders: true)
        env.builders.keys.should == []
        env.add_builder(Rscons::Builders::Object.new)
        env.builders.keys.should == ["Object"]
      end
    end

    describe "#get_build_fname" do
      context "with no build directories" do
        it "returns the name of the source file with suffix changed" do
          env = Environment.new
          env.get_build_fname("src/dir/file.c", ".o").should == "src/dir/file.o"
          env.get_build_fname("src\\dir\\other.d", ".a").should == "src/dir/other.a"
          env.get_build_fname("source.cc", ".o").should == "source.o"
        end

        context "with a build_root" do
          it "uses the build_root unless the path is absolute" do
            env = Environment.new
            env.build_root = "build/proj"
            env.get_build_fname("src/dir/file.c", ".o").should == "build/proj/src/dir/file.o"
            env.get_build_fname("/some/lib.c", ".a").should == "/some/lib.a"
            env.get_build_fname("C:\\abspath\\mod.cc", ".o").should == "C:/abspath/mod.o"
            env.get_build_fname("build\\proj\\generated.c", ".o").should == "build/proj/generated.o"
            env.get_build_fname("build/proj.XX", ".yy").should == "build/proj/build/proj.yy"
          end
        end
      end

      context "with build directories" do
        it "uses the build directories to create the output file name" do
          env = Environment.new
          env.build_dir("src", "bld")
          env.build_dir(%r{^libs/([^/]+)}, 'build/libs/\1')
          env.get_build_fname("src/input.cc", ".o").should == "bld/input.o"
          env.get_build_fname("libs/lib1/some/file.c", ".o").should == "build/libs/lib1/some/file.o"
          env.get_build_fname("libs/otherlib/otherlib.cc", ".o").should == "build/libs/otherlib/otherlib.o"
          env.get_build_fname("other_directory/o.d", ".a").should == "other_directory/o.a"
        end

        context "with a build_root" do
          it "uses the build_root unless a build directory matches or the path is absolute" do
            env = Environment.new
            env.build_dir("src", "bld")
            env.build_dir(%r{^libs/([^/]+)}, 'build/libs/\1')
            env.build_root = "bldit"

            env.get_build_fname("src/input.cc", ".o").should == "bld/input.o"
            env.get_build_fname("libs/lib1/some/file.c", ".o").should == "build/libs/lib1/some/file.o"
            env.get_build_fname("libs/otherlib/otherlib.cc", ".o").should == "build/libs/otherlib/otherlib.o"
            env.get_build_fname("other_directory/o.d", ".a").should == "bldit/other_directory/o.a"
            env.get_build_fname("bldit/some/mod.d", ".a").should == "bldit/some/mod.a"
          end
        end
      end
    end

    describe "#[]" do
      it "allows reading construction variables" do
        env = Environment.new
        env["CFLAGS"] = ["-g", "-Wall"]
        env["CFLAGS"].should == ["-g", "-Wall"]
      end
    end

    describe "#[]=" do
      it "allows writing construction variables" do
        env = Environment.new
        env["CFLAGS"] = ["-g", "-Wall"]
        env["CFLAGS"] -= ["-g"]
        env["CFLAGS"] += ["-O3"]
        env["CFLAGS"].should == ["-Wall", "-O3"]
        env["other_var"] = "val33"
        env["other_var"].should == "val33"
      end
    end

    describe "#append" do
      it "allows adding many construction variables at once" do
        env = Environment.new
        env["CFLAGS"] = ["-g"]
        env["CPPPATH"] = ["inc"]
        env.append("CFLAGS" => ["-Wall"], "CPPPATH" => ["include"])
        env["CFLAGS"].should == ["-Wall"]
        env["CPPPATH"].should == ["include"]
      end
    end

    describe "#process" do
      it "runs builders for all of the targets specified" do
        env = Environment.new
        env.Program("a.out", "main.c")

        cache = "cache"
        Cache.should_receive(:instance).and_return(cache)
        cache.should_receive(:clear_checksum_cache!)
        env.should_receive(:run_builder).with(anything, "a.out", ["main.c"], cache, {}).and_return(true)
        cache.should_receive(:write)

        env.process
      end

      it "builds dependent targets first" do
        env = Environment.new
        env.Program("a.out", "main.o")
        env.Object("main.o", "other.cc")

        cache = "cache"
        Cache.should_receive(:instance).and_return(cache)
        cache.should_receive(:clear_checksum_cache!)
        env.should_receive(:run_builder).with(anything, "main.o", ["other.cc"], cache, {}).and_return("main.o")
        env.should_receive(:run_builder).with(anything, "a.out", ["main.o"], cache, {}).and_return("a.out")
        cache.should_receive(:write)

        env.process
      end

      it "raises a BuildError when building fails" do
        env = Environment.new
        env.Program("a.out", "main.o")
        env.Object("main.o", "other.cc")

        cache = "cache"
        Cache.should_receive(:instance).and_return(cache)
        cache.should_receive(:clear_checksum_cache!)
        env.should_receive(:run_builder).with(anything, "main.o", ["other.cc"], cache, {}).and_return(false)
        cache.should_receive(:write)

        expect { env.process }.to raise_error BuildError, /Failed.to.build.main.o/
      end

      it "writes the cache when the Builder raises an exception" do
        env = Environment.new
        env.Object("module.o", "module.c")

        cache = "cache"
        Cache.should_receive(:instance).and_return(cache)
        cache.should_receive(:clear_checksum_cache!)
        env.stub(:run_builder) do |builder, target, sources, cache, vars|
          raise "Ruby exception thrown by builder"
        end
        cache.should_receive(:write)

        expect { env.process }.to raise_error RuntimeError, /Ruby exception thrown by builder/
      end
    end

    describe "#clear_targets" do
      it "resets @targets to an empty hash" do
        env = Environment.new
        env.Program("a.out", "main.o")
        expect(env.instance_variable_get(:@targets).keys).to eq(["a.out"])

        env.clear_targets

        expect(env.instance_variable_get(:@targets).keys).to eq([])
      end
    end

    describe "#build_command" do
      it "returns a command based on the variables in the Environment" do
        env = Environment.new
        env["path"] = ["dir1", "dir2"]
        env["flags"] = ["-x", "-y", "${specialflag}"]
        env["specialflag"] = "-z"
        template = ["cmd", "-I${path}", "${flags}", "${_source}", "${_dest}"]
        cmd = env.build_command(template, "_source" => "infile", "_dest" => "outfile")
        cmd.should == ["cmd", "-Idir1", "-Idir2", "-x", "-y", "-z", "infile", "outfile"]
      end
    end

    describe "#expand_varref" do
      it "returns the fully expanded variable reference" do
        env = Environment.new
        env["path"] = ["dir1", "dir2"]
        env["flags"] = ["-x", "-y", "${specialflag}"]
        env["specialflag"] = "-z"
        env["foo"] = {}
        env.expand_varref(["-p${path}", "${flags}"]).should == ["-pdir1", "-pdir2", "-x", "-y", "-z"]
        env.expand_varref("foo").should == "foo"
        expect {env.expand_varref("${foo}")}.to raise_error /expand.a.variable.reference/
        env.expand_varref("${specialflag}").should == "-z"
        env.expand_varref("${path}").should == ["dir1", "dir2"]
      end
    end

    describe "#execute" do
      context "with echo: :short" do
        context "with no errors" do
          it "prints the short description and executes the command" do
            env = Environment.new(echo: :short)
            env.should_receive(:puts).with("short desc")
            env.should_receive(:system).with("a", "command").and_return(true)
            env.execute("short desc", ["a", "command"])
          end
        end

        context "with errors" do
          it "prints the short description, executes the command, and prints the failed command line" do
            env = Environment.new(echo: :short)
            env.should_receive(:puts).with("short desc")
            env.should_receive(:system).with("a", "command").and_return(false)
            $stdout.should_receive(:write).with("Failed command was: ")
            env.should_receive(:puts).with("a command")
            env.execute("short desc", ["a", "command"])
          end
        end
      end

      context "with echo: :command" do
        it "prints the command executed and executes the command" do
          env = Environment.new(echo: :command)
          env.should_receive(:puts).with("a command '--arg=val with spaces'")
          env.should_receive(:system).with({modified: :environment}, "a", "command", "--arg=val with spaces", {opt: :val}).and_return(false)
          env.execute("short desc", ["a", "command", "--arg=val with spaces"], env: {modified: :environment}, options: {opt: :val})
        end
      end
    end

    describe "#method_missing" do
      it "calls the original method missing when the target method is not a known builder" do
        env = Environment.new
        expect {env.foobar}.to raise_error /undefined method .foobar./
      end

      it "records the target when the target method is a known builder" do
        env = Environment.new
        env.instance_variable_get(:@targets).should == {}
        env.Program("target", ["src1", "src2"], var: "val")
        target = env.instance_variable_get(:@targets)["target"]
        target.should_not be_nil
        target[:builder].is_a?(Builder).should be_true
        target[:sources].should == ["src1", "src2"]
        target[:vars].should == {var: "val"}
        target[:args].should == []
      end

      it "raises an error when vars is not a Hash" do
        env = Environment.new
        expect { env.Program("a.out", "main.c", "other") }.to raise_error /Unexpected construction variable set/
      end
    end

    describe "#depends" do
      it "records the given dependencies in @user_deps" do
        env = Environment.new
        env.depends("foo", "bar", "baz")
        env.instance_variable_get(:@user_deps).should == {"foo" => ["bar", "baz"]}
      end
      it "records user dependencies only once" do
        env = Environment.new
        env.instance_variable_set(:@user_deps, {"foo" => ["bar"]})
        env.depends("foo", "bar", "baz")
        env.instance_variable_get(:@user_deps).should == {"foo" => ["bar", "baz"]}
      end
    end

    describe "#build_sources" do
      class ABuilder < Builder
        def produces?(target, source, env)
          target =~ /\.ab_out$/ and source =~ /\.ab_in$/
        end
      end

      it "finds and invokes a builder to produce output files with the requested suffixes" do
        cache = "cache"
        env = Environment.new
        env.add_builder(ABuilder.new)
        env.builders["Object"].should_receive(:run).with("mod.o", ["mod.c"], cache, env, anything).and_return("mod.o")
        env.builders["ABuilder"].should_receive(:run).with("mod2.ab_out", ["mod2.ab_in"], cache, env, anything).and_return("mod2.ab_out")
        env.build_sources(["precompiled.o", "mod.c", "mod2.ab_in"], [".o", ".ab_out"], cache, {}).should == ["precompiled.o", "mod.o", "mod2.ab_out"]
      end
    end

    describe "#run_builder" do
      it "modifies the construction variables using given build hooks and invokes the builder" do
        env = Environment.new
        env.add_build_hook do |build_op|
          if build_op[:sources].first =~ %r{src/special}
            build_op[:vars]["CFLAGS"] += ["-O3", "-DSPECIAL"]
          end
        end
        env.builders["Object"].stub(:run) do |target, sources, cache, env, vars|
          vars["CFLAGS"].should == []
        end
        env.run_builder(env.builders["Object"], "build/normal/module.o", ["src/normal/module.c"], "cache", {})
        env.builders["Object"].stub(:run) do |target, sources, cache, env, vars|
          vars["CFLAGS"].should == ["-O3", "-DSPECIAL"]
        end
        env.run_builder(env.builders["Object"], "build/special/module.o", ["src/special/module.c"], "cache", {})
      end
    end

    describe "#shell" do
      it "executes the given shell command and returns the results" do
        env = Environment.new
        expect(env.shell("echo hello").strip).to eq("hello")
      end
      it "determines shell flag to be /c when SHELL is specified as 'cmd'" do
        env = Environment.new
        env["SHELL"] = "cmd"
        IO.should_receive(:popen).with(["cmd", "/c", "my_cmd"])
        env.shell("my_cmd")
      end
      it "determines shell flag to be -c when SHELL is specified as something else" do
        env = Environment.new
        env["SHELL"] = "my_shell"
        IO.should_receive(:popen).with(["my_shell", "-c", "my_cmd"])
        env.shell("my_cmd")
      end
    end

    describe "#parse_flags" do
      it "executes the shell command and parses the returned flags when the input argument begins with !" do
        env = Environment.new
        env["CFLAGS"] = ["-g"]
        env.should_receive(:shell).with("my_command").and_return(%[-arch my_arch -Done=two -include ii -isysroot sr -Iincdir -Llibdir -lmy_lib -mno-cygwin -mwindows -pthread -std=c99 -Wa,'asm,args 1 2' -Wl,linker,"args 1 2" -Wp,cpp,args,1,2 -arbitrary +other_arbitrary some_lib /a/b/c/lib])
        rv = env.parse_flags("!my_command")
        expect(rv).to eq({
          "CCFLAGS" => %w[-arch my_arch -include ii -isysroot sr -mno-cygwin -pthread -arbitrary +other_arbitrary],
          "LDFLAGS" => %w[-arch my_arch -isysroot sr -mno-cygwin -mwindows -pthread] + ["linker", "args 1 2"] + %w[+other_arbitrary],
          "CPPPATH" => %w[incdir],
          "LIBS" => %w[my_lib some_lib /a/b/c/lib],
          "LIBPATH" => %w[libdir],
          "CPPDEFINES" => %w[one=two],
          "CFLAGS" => %w[-std=c99],
          "ASFLAGS" => ["asm", "args 1 2"],
          "CPPFLAGS" => %w[cpp args 1 2],
        })
        expect(env["CFLAGS"]).to eq(["-g"])
        expect(env["ASFLAGS"]).to eq([])
        env.merge_flags(rv)
        expect(env["CFLAGS"]).to eq(["-g", "-std=c99"])
        expect(env["ASFLAGS"]).to eq(["asm", "args 1 2"])
      end
    end

    describe "#parse_flags!" do
      it "parses the given build flags and merges them into the Environment" do
        env = Environment.new
        env["CFLAGS"] = ["-g"]
        rv = env.parse_flags!("-I incdir -D my_define -L /a/libdir -l /some/lib")
        expect(rv).to eq({
          "CPPPATH" => %w[incdir],
          "LIBS" => %w[/some/lib],
          "LIBPATH" => %w[/a/libdir],
          "CPPDEFINES" => %w[my_define],
        })
        expect(env["CPPPATH"]).to eq(%w[incdir])
        expect(env["LIBS"]).to eq(%w[/some/lib])
        expect(env["LIBPATH"]).to eq(%w[/a/libdir])
        expect(env["CPPDEFINES"]).to eq(%w[my_define])
      end
    end

    describe "#merge_flags" do
      it "appends array contents and replaces other variable values" do
        env = Environment.new
        env["CPPPATH"] = ["incdir"]
        env["CSUFFIX"] = ".x"
        env.merge_flags("CPPPATH" => ["a"], "CSUFFIX" => ".c")
        expect(env["CPPPATH"]).to eq(%w[incdir a])
        expect(env["CSUFFIX"]).to eq(".c")
      end
    end

    describe ".parse_makefile_deps" do
      it 'handles dependencies on one line' do
        File.should_receive(:read).with('makefile').and_return(<<EOS)
module.o: source.cc
EOS
        Environment.parse_makefile_deps('makefile', 'module.o').should == ['source.cc']
      end

      it 'handles dependencies split across many lines' do
        File.should_receive(:read).with('makefile').and_return(<<EOS)
module.o: module.c \\
  module.h \\
  other.h
EOS
        Environment.parse_makefile_deps('makefile', 'module.o').should == [
          'module.c', 'module.h', 'other.h']
      end
    end
  end
end
