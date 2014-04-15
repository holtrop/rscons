# Rscons

Software construction library inspired by SCons and implemented in Ruby

[![Gem Version](https://badge.fury.io/rb/rscons.png)](http://badge.fury.io/rb/rscons)

## Installation

Add this line to your application's Gemfile:

    gem "rscons"

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install rscons

## Usage

Rscons is a Ruby library.
It can be called from a standalone Ruby script or it can be used with rake and
called from your Rakefile.

### Example: Building a C Program

```ruby
Rscons::Environment.new do |env|
  env["CFLAGS"] << "-Wall"
  env.Program("program", Dir["**/*.c"])
end
```

### Example: Building a D Program

```ruby
Rscons::Environment.new do |env|
  env["DFLAGS"] << "-Wall"
  env.Program("program", Dir["**/*.d"])
end
```

### Example: Cloning an Environment

```ruby
main_env = Rscons::Environment.new do |env|
  # Store object files from sources under "src" in "build/main"
  env.build_dir("src", "build/main")
  env["CFLAGS"] = ["-DSOME_DEFINE", "-O3"]
  env["LIBS"] = ["SDL"]
  env.Program("program", Dir["src/**/*.cc"])
end

debug_env = main_env.clone do |env|
  # Store object files from sources under "src" in "build/debug"
  env.build_dir("src", "build/debug")
  env["CFLAGS"] -= ["-O3"]
  env["CFLAGS"] += ["-g", "-O0"]
  env.Program("program-debug", Dir["src/**/*.cc"])
end
```

### Example: Custom Builder

Custom builders are implemented as classes which extend from `Rscons::Builder`.
The builder must have a `run` method which is called to invoke the builder.
The `run` method should return the name of the target built on success, and
`false` on failure.

```ruby
class GenerateFoo < Rscons::Builder
  def run(target, sources, cache, env, vars)
    cache.mkdir_p(File.dirname(target))
    File.open(target, "w") do |fh|
      fh.puts <<EOF
#define GENERATED 42
EOF
    end
    target
  end
end

Rscons::Environment.new do |env|
  env.add_builder(GenerateFoo.new)
  env.GenerateFoo("foo.h", [])
  env.Program("a.out", Dir["*.c"])
end
```

### Example: Custom Builder That Only Regenerates When Necessary

```ruby
class CmdBuilder < Rscons::Builder
  def run(target, sources, cache, env, vars)
    cmd = ["cmd", "-i", sources.first, "-o", target]
    unless cache.up_to_date?(target, cmd, sources, env)
      cache.mkdir_p(File.dirname(target))
      system(cmd)
      cache.register_build(target, cmd, sources, env)
    end
    target
  end
end

Rscons::Environment.new do |env|
  env.add_builder(CmdBuilder.new)
  env.CmdBuilder("foo.gen", "foo_gen.cfg")
end
```

### Example: Custom Builder That Generates Multiple Output Files

```ruby
class CModuleGenerator < Rscons::Builder
  def run(target, sources, cache, env, vars)
    c_fname = target
    h_fname = target.sub(/\.c$/, ".h")
    cmd = ["generate_c_and_h", sources.first, c_fname, h_fname]
    unless cache.up_to_date?([c_fname, h_fname], cmd, sources, env)
      cache.mkdir_p(File.dirname(target))
      system(cmd)
      cache.register_build([c_fname, h_fname], cmd, sources, env)
    end
    target
  end
end

Rscons::Environment.new do |env|
  env.add_builder(CModuleGenerator.new)
  env.CModuleGenerator("build/foo.c", "foo_gen.cfg")
end
```

### Example: Custom Builder Using Builder#standard_build()

The `standard_build` method from the `Rscons::Builder` base class can be used
when the builder needs to execute a system command to produce the target file.
The `standard_build` method will return the correct value so its return value
can be used as the return value from the `run` method.

```ruby
class CmdBuilder < Rscons::Builder
  def run(target, sources, cache, env, vars)
    cmd = ["cmd", "-i", sources.first, "-o", target]
    standard_build("CmdBld #{target}", target, cmd, sources, env, cache)
  end
end

Rscons::Environment.new do |env|
  env.add_builder(CmdBuilder.new)
  env.CmdBuilder("foo.gen", "foo_gen.cfg")
end
```

### Example: Using different compilation flags for some sources

```ruby
Rscons::Environment.new do |env|
  env["CFLAGS"] = ["-O3", "-Wall", "-DDEFINE"]
  env.add_build_hook do |build_op|
    if build_op[:target] =~ %r{build/third-party}
      build_op[:vars]["CFLAGS"] -= ["-Wall"]
    end
  end
  env.build_dir("src", "build")
  env.Program("program", Dir["**/*.cc"])
end
```

Each build hook block will be invoked for every build operation, so the block
should test the target or sources if its action should only apply to some
subset of build targets or source files.

The `build_op` parameter to the build hook block is a Hash describing the
build operation with the following keys:
* `:builder` - `Builder` instance in use
* `:env` - `Environment` calling the build hook; note that this may be
  different from the Environment that the build hook was added to in the case
  that the original Environment was cloned with build hooks!
* `:target` - `String` name of the target file
* `:sources` - `Array` of the source files
* `:vars` - `Rscons::VarSet` containing the construction variables to use.
  The build hook can overwrite entries in `build_op[:vars]` to alter the
  construction variables in use for this specific build operation.

### Example: Creating a static library

```ruby
Rscons::Environment.new do |env|
  env.Library("mylib.a", Dir["src/**/*.c"])
end
```

### Example: Creating a C++ parser source from a Yacc/Bison input file

```ruby
Rscons::Environment.new do |env|
  env.CFile("#{env.build_root}/parser.tab.cc", "parser.yy")
end
```

## Details

### Builders

Rscons ships with a number of builders:

* CFile, which builds a C or C++ source file from a lex or yacc input file
* Disassemble, which disassembles an object file to a disassembly listing
* Library, which collects object files into a static library archive file
* Object, which compiles source files to produce an object file
* Preprocess, which invokes the C/C++ preprocessor on a source file
* Program, which links object files to produce an executable

If you want to create an Environment that does not contain any builders,
you can use the `exclude_builders` key to the Environment constructor.

#### CFile

```ruby
env.CFile(target, source)
# Example
env.CFile("parser.c", "parser.y")
```

The CFile builder will generate a C or C++ source file from a lex (.l, .ll)
or yacc (.y, .yy) input file.

#### Disassemble

```ruby
env.Disassemble(target, source)
# Example
env.Disassemble("module.dis", "module.o")
```

The Disassemble builder generates a disassembly listing using objdump from
and object file.

#### Library

```ruby
env.Library(target, sources)
# Example
env.Library("lib.a", Dir["src/**/*.c"])
```

The Library builder creates a static library archive from the given source
files.

#### Object

```ruby
env.Object(target, sources)
# Example
env.Object("module.o", "module.c")
```

The Object builder compiles the given sources to an object file.

#### Preprocess

```ruby
env.Preprocess(target, source)
# Example
env.Preprocess("module-preprocessed.cc", "module.cc")
```

The Preprocess builder invokes either ${CC} or ${CXX} (depending on if the
source contains an extension in ${CXXSUFFIX} or not) and writes the
preprocessed output to the target file.

#### Program

```ruby
env.Program(target, sources)
# Example
env.Program("myprog", Dir["src/**/*.cc"])
```

The Program builder compiles and links the given sources to an executable file.
Object files or source files can be given as `sources`.

### Managing Environments

An Rscons::Environment consists of:

* a collection of construction variables
* a collection of builders
* a mapping of build directories from source directories
* a default build root to apply if no build directories are matched
* a collection of targets to build
* a collection of build hooks

When cloning an environment, by default the construction variables and builders
are cloned, but the new environment does not inherit any of the targets, build
hooks, build directories, or the build root from the source environment.

The set of environment attributes that are cloned is controllable via the
`:clone` option to the `#clone` method.
For example, `env.clone(clone: :all)` will include construction variables,
builders, build hooks, build directories, and the build root.

The set of pending targets is never cloned.

Cloned environments contain "deep copies" of construction variables.
For example, in:

```ruby
base_env = Rscons::Environment.new
base_env["CPPPATH"] = ["one", "two"]
cloned_env = base_env.clone
cloned_env["CPPPATH"] << "three"
```

`base_env["CPPPATH"]` will not include "three".

### Construction Variable Naming

* uppercase strings - the default construction variables that Rscons uses
* symbols, lowercase strings - reserved as user-defined construction variables

### API documentation

Documentation for the complete Rscons API can be found at
http://rubydoc.info/github/holtrop/rscons/frames.

## Release Notes

### v1.4.0

- add CFile builder
- add Disassemble builder
- add Preprocess builder
- pass the Environment object to build hooks in the :env key of the build_op parameter
- expand target/source paths beginning with "^/" to be relative to the Environment's build root
- many performance improvements, including:
  - use JSON instead of YAML for the cache to improve loading speed (Issue #7)
  - store a hash of the build command instead of the full command contents in the cache
  - implement copy-on-write semantics for construction variables when cloning Environments
  - only load the cache once instead of on each Environment#process
  - only write the cache when something has changed
- fix Cache#mkdir_p to handle relative paths (Issue #5)
- flush the cache to disk if a builder raises an exception (Issue #4)

### v1.3.0

- change Environment#execute() options parameter to accept the following options keys:
  - :env to pass an environment Hash to Kernel#system
  - :options to pass an options Hash to Kernel#system

### v1.2.0

- add :clone option to Environment#clone to control exactly which Environment attributes are cloned
- allow nil to be passed in to Environment#build_root=

### v1.1.0

- Change Cache#up_to_date?() and #register_build() to accept a single target
  file or an array of target file names

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
