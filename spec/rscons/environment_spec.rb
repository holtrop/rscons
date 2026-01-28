module Rscons
  describe Environment do
    before(:each) do
      Cache.instance["configuration_data"] = {"configured" => true}
    end

    describe "#initialize" do
      it "adds the default builders when they are not excluded" do
        env = Environment.new
        expect(env.builders.size).to be > 0
        expect(env.builders.map {|name, builder| builder.is_a?(Class)}.all?).to be_truthy
        expect(env.builders.find {|name, builder| name == "Object"}).to_not be_nil
        expect(env.builders.find {|name, builder| name == "Program"}).to_not be_nil
        expect(env.builders.find {|name, builder| name == "Library"}).to_not be_nil
      end

      it "excludes the default builders with exclude_builders: :all" do
        env = Environment.new(exclude_builders: true)
        expect(env.builders.size).to eq 0
      end
    end

    describe "#clone" do
      it 'creates unique copies of each construction variable' do
        env = Environment.new
        env["CPPPATH"] << "path1"
        env2 = env.clone
        env2["CPPPATH"] << "path2"
        expect(env["CPPPATH"]).to eq ["path1"]
        expect(env2["CPPPATH"]).to eq ["path1", "path2"]
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
    end

    describe "#add_builder" do
      it "adds the builder to the list of builders" do
        env = Environment.new(exclude_builders: true)
        expect(env.builders.keys).to eq []
        env.add_builder(Rscons::Builders::Object)
        expect(env.builders.keys).to eq ["Object"]
      end

      it "adds a new simple builder to the list of builders" do
        env = Environment.new(exclude_builders: true)
        expect(env.builders.keys).to eq []
        env.add_builder(:Foo) {}
        expect(env.builders.keys).to eq ["Foo"]
      end
    end

    describe "#[]" do
      it "allows reading construction variables" do
        env = Environment.new
        env["CFLAGS"] = ["-g", "-Wall"]
        expect(env["CFLAGS"]).to eq ["-g", "-Wall"]
      end
    end

    describe "#[]=" do
      it "allows writing construction variables" do
        env = Environment.new
        env["CFLAGS"] = ["-g", "-Wall"]
        env["CFLAGS"] -= ["-g"]
        env["CFLAGS"] += ["-O3"]
        expect(env["CFLAGS"]).to eq ["-Wall", "-O3"]
        env["other_var"] = "val33"
        expect(env["other_var"]).to eq "val33"
      end
    end

    describe "#append" do
      it "allows adding many construction variables at once" do
        env = Environment.new
        env["CFLAGS"] = ["-g"]
        env["CPPPATH"] = ["inc"]
        env.append("CFLAGS" => ["-Wall"], "CPPPATH" => ["include"])
        expect(env["CFLAGS"]).to eq ["-Wall"]
        expect(env["CPPPATH"]).to eq ["include"]
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
        expect(cmd).to eq ["cmd", "-Idir1", "-Idir2", "-x", "-y", "-z", "infile", "outfile"]
      end
    end

    describe "#expand_varref" do
      it "returns the fully expanded variable reference" do
        env = Environment.new
        env["path"] = ["dir1", "dir2"]
        env["flags"] = ["-x", "-y", "${specialflag}"]
        env["specialflag"] = "-z"
        env["foo"] = {}
        expect(env.expand_varref(["-p${path}", "${flags}"])).to eq ["-pdir1", "-pdir2", "-x", "-y", "-z"]
        expect(env.expand_varref("foo")).to eq "foo"
        expect {env.expand_varref("${foo}")}.to raise_error /Unknown.construction.variable.type/
        expect(env.expand_varref("${specialflag}")).to eq "-z"
        expect(env.expand_varref("${path}")).to eq ["dir1", "dir2"]
      end
    end

    describe "#method_missing" do
      it "calls the original method missing when the target method is not a known builder" do
        env = Environment.new
        expect {env.foobar}.to raise_error /undefined method .foobar./
      end

      it "raises an error when vars is not a Hash" do
        env = Environment.new
        expect { env.Program("a.out", "main.c", "other") }.to raise_error /Unexpected construction variable set/
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
        expect(IO).to receive(:popen).with(["cmd", "/c", "my_cmd"])
        env.shell("my_cmd")
      end
      it "determines shell flag to be -c when SHELL is specified as something else" do
        env = Environment.new
        env["SHELL"] = "my_shell"
        expect(IO).to receive(:popen).with(["my_shell", "-c", "my_cmd"])
        env.shell("my_cmd")
      end
    end

    describe "#parse_flags" do
      it "executes the shell command and parses the returned flags when the input argument begins with !" do
        env = Environment.new
        env["CCFLAGS"] = ["-g"]
        expect(env).to receive(:shell).with("my_command").and_return(%[-arch my_arch -Done=two -include ii -isysroot sr -Iincdir -Llibdir -lmy_lib -mno-cygwin -mwindows -pthread -std=c99 -Wa,'asm,args 1 2' -Wl,linker,"args 1 2" -Wp,cpp,args,1,2 -arbitrary +other_arbitrary some_lib /a/b/c/lib])
        rv = env.parse_flags("!my_command")
        expect(rv).to eq({
          "CCFLAGS" => %w[-arch my_arch -include ii -isysroot sr -mno-cygwin -pthread -std=c99 -arbitrary +other_arbitrary],
          "LDFLAGS" => %w[-arch my_arch -isysroot sr -mno-cygwin -mwindows -pthread] + ["linker", "args 1 2"] + %w[+other_arbitrary],
          "CPPPATH" => %w[incdir],
          "LIBS" => %w[my_lib some_lib /a/b/c/lib],
          "LIBPATH" => %w[libdir],
          "CPPDEFINES" => %w[one=two],
          "ASFLAGS" => ["asm", "args 1 2"],
          "CPPFLAGS" => %w[cpp args 1 2],
        })
        expect(env["CCFLAGS"]).to eq(["-g"])
        expect(env["ASFLAGS"]).to eq([])
        env.merge_flags(rv)
        expect(env["CCFLAGS"]).to eq(%w[-g -arch my_arch -include ii -isysroot sr -mno-cygwin -pthread -std=c99 -arbitrary +other_arbitrary])
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

    describe "#find_finished_thread" do
      it "raises an error if called with nonblock=false and no threads to wait for" do
        env = Environment.new
        expect {env.__send__(:find_finished_thread, false)}.to raise_error /No threads to wait for/
      end
    end
  end
end
