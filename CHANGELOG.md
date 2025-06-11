## v3.3.0

### New Features

- Add support for Ruby 3.4.
- Fix up some macOS test cases.
- #177 - Remove dependency on base64
- #175 - Add support for building object files from LLVM assembly sources

## v3.2.0

### New Features

- #171 - Place object files next to source files for source files in build directory
- #170 - Use top-level build directory as environment build directory for unnamed environments
- #167 - Add upgrading instructions
- #166 - Replace CFile builder with Yacc and Lex builders

### Fixes

- #172 - Fix configuration checks performed with ldc2 compiler
- #169 - Output a better error when pkg-config is not found
- #168 - Cannot output binary to an environment's build root with the same name as the top-level source directory
- #164 - Improve DSL method documentation

## v3.1.0

### New Features

- #162 - Improve configuration error messages
- #163 - Ruby 3.2 compatibility

### Fixes

- #161 - builder registered during build hooks should increase build step count

## v3.0.2

### Fixes

- #159 - Compiler check configure methods should respect :use flag
- #160 - Configure parameters should not be stored as unscoped construction variables

## v3.0.1

### Fixes

- #156 - Avoid running configure operation twice
- #157 - Load configure task arguments before early configure operations
- #158 - Do not configure for clean tasks when not yet configured

## v3.0.0

- #136 - Move rsconscache into build directory
- #140 - Support naming environments
- #143 - Add Size builder
- #142 - Add 'sh' script DSL method
- #144 - Add FileUtils class methods to script DSL
- #145 - Support environment variable to set rscons build directory
- #146 - Add ^^/ shortcut to top-level build directory
- #139 - Add tasks
- #147 - Add task options
- #148 - Add license/copyright to distributable script
- #150 - Add env.expand() shortcut method to expand paths and construction variables
- #152 - Add download script method
- #153 - Allow passing spawn options to sh
- #154 - Record build directory absolute path
- #149 - Add shortcut method for creating environments
- #131 - Only configure if necessary
- #151 - Store configure task parameters in configuration cache data
- #137 - Add variants
- #155 - Add build_dir script method

## v2.3.0

### New Features

- #125 - Support subsidiary Rsconscript files
- #126 - Add PATH manipulation methods

### Fixes

- #121 - env.depends() does not work with build-root-relative "^/" paths
- #130 - Document -f command line option
- #133 - Clarify failed command error message indicating to run -F
- #134 - Document CMD_STDOUT variable for Command builder
- #135 - Write dependency file to build directory when user invokes Object builder directly
- #141 - Document phony targets

## v2.2.0

### New Features

- #120 - improve support for MSYS2
- #119 - add failure messages for failed configuration checks
- #118 - compiler checks should support cross-compilers and freestanding compilers

## v2.1.0

### New Features

- #117 - ruby 2.7 compatibility

## v2.0.2

### Fixes

- #113 - distinguish object files built from multiple sources with the same base name but different extensions

## v2.0.1

### Fixes

- #112 - Install builder cannot replace a currently executing binary on Linux

## v2.0.0

- convert rscons from a Ruby gem to a standalone script
- compress rscons distributable script
- add configure operation to detect compilers, check for headers/libraries, etc... (invoked automatically if needed)
- Environments store builder classes instead of instances of builder classes
- use a separate Builder instance for each build operation
- load Rsconscript from Rsconscript/Rsconscript.rb instead of Rsconsfile
- drop support for builder run methods using the old 5 parameter signature
- remove Environment#build_dir
- set Environment build root in configure step
- remove Builder#finalize (now #run called repeatedly until builder completes)
- remove Builder#setup
- remove Builder#features and Builder#produces?
- add functionality to allow builders to wait on Ruby threads or other builders
- add install/uninstall/distclean command-line operations
- preserve makefile dependency files under build directory
- remove a few deprecated methods
- pass a Builder instance to build hooks instead of a build operation Hash
- support a basic markup syntax in builder run messages to colorize target/source files
- hide (but store) failed compilation command by default so the user doesn't have to scroll back as much to see compiler output
- refactor to remove some redundancy among built-in builders
- track object file source language (correctly determine linker when only passed object files previously built by particular toolchains)
- add barriers
- add InstallDirectory builder
- change Install builder to copy files on 'install' operation
- add "prefix" construction variable based on configured installation prefix
- allow passing builder objects as sources to build targets
- differentiate 'build' targets from 'install' targets in cache contents
- add verbose mode
- show build progress as a percentage in builder output messages
- various performance improvements
- wrote a new user guide
- added new website ([https://holtrop.github.io/rscons/](https://holtrop.github.io/rscons/))
- added new logo

## v1.17.0

### New Features

- allow construction variable expansion on `true` and `false` values.
- remove makefile target name check when parsing dependencies

## v1.16.0

### New Features

- Add `Rscons.glob`
- Support command-line variables
- improve debuggability of `cache.up_to_date?`
- allow passing a VarSet into cache methods

### Fixes

- generate dependencies for D builds

## v1.15.0

- allow json 1.x or 2.x

## v1.14.0

### New Features

- #45 - Add `Rscons::VarSet#values_at`

### Fixes

- #44 - `Environment#print_builder_run_message` should support string commands

## v1.13.0

### New Features

- #43 - Add ability to record side-effect file production

## v1.12.0

### New Features

- #40 - env.depends should imply `env.build_after`
- #41 - be more colorful

### Fixes

- #39 - wait for in-progress subcommands to complete on build failure
- #42 - cloned Environments should inherit `n_threads`

## v1.11.1

### Fixes

- fix the circular build dependency detection logic

## v1.11.0

### New Features

- Change default Environment :clone option to :all to clone all attributes
- #38 - raise error when circular dependencies are found
- #34 - Allow overriding `n_threads` on a per-Environment level

### Fixes

- #35 - `env.build_after` should expand paths
- #36 - `SHCFLAGS` and `SHCXXFLAGS` should inherit non-SH flags by default
- #37 - Fix non-blocking thread-wait if `Rscons.n_threads` is set to 0

## v1.10.0

### New Features

- #23 - add parallelization - builds are now parallelized by default
- #31 - add LEXSUFFIX, YACCSUFFIX construction variables
- #30 - place object files for absolute source paths under build_root
- #28 - support redirecting standard output using the Command builder
- Always use a build root and default it to "build"
- Add builder features
- #8 - add SharedObject and SharedLibrary builders

### Fixes

- expand target and source paths before calling `Builder#create_build_target`
- #29 - fix `PROGSUFFIX` handling
- #32 - Pre-build hooks do not respect modified key values

## v1.9.3

- `Environment#parse_flags` should put -std=XXX flags in CCFLAGS, not CFLAGS

## v1.9.2

- allow phony targets in conjunction with build roots

## v1.9.1

- change *SUFFIX defaults to arrays
- add various C++ file suffixes
- use ${INCPREFIX} instead of hard-coded "-I" in Preprocess builder

## v1.9.0

### New Features

- #6 - add Install and Copy builders
- #22 - allow overriding Command builder short description with `CMD_DESC` variable
- #24 - add "rscons" executable
- #25 - add support for phony targets given as Symbols instead of Strings
- #26 - support registering multiple build targets with the same target name
- #27 - add Directory builder

### Fixes

- #20 - fix variable references that expand to arrays in build target sources
- #21 - rework Preprocess builder to consider deep dependencies
- fix `Rscons.set_suffix` to append the given suffix if the filename has none
- remove ${CFLAGS} from default `CPP_CMD`

## v1.8.1

- fix Environment#dump when construction variables are symbols

## v1.8.0

- new Command builder to execute arbitrary user commands
- new SimpleBuilder class
  - create new builders quickly by passing a block to `Environment#add_builder`
- improved YARD documentation
- add Environment#dump to debug Environment construction variables

## v1.7.0

- allow build hooks to register new build targets
- add post-build hooks (register with `Environment#add_post_build_hook`)
- clear all build targets after processing an Environment
- allow trailing slashes in arguments to `Environment#build_dir`

## v1.6.1

- add DEPFILESUFFIX construction variable to override dependency file suffix
- fix Environment#depends to expand its arguments for construction variables

## v1.6.0

- support lambdas as construction variable values

## v1.5.0

- add "json" as a runtime dependency
- update construction variables to match SCons more closely
  - add `CPPDEFPREFIX`, `INCPREFIX`, `CPPDEFINES`, `CCFLAGS`, `LIBDIRPREFIX`, and `LIBLINKPREFIX`
- add `Environment#shell`
- add `Environment#parse_flags`, `#parse_flags!`, `#merge_flags`
- unbuffer `$stdout` by default
- add `PROGSUFFIX` construction variable (defaults to `.exe` on MinGW/Cygwin)
- add `Rscons::BuildTarget` and `Builder#create_build_target`
- update specs to RSpec 3.x and fix to run on MinGW/Cygwin/Linux
- add YARD documentation to get to 100% coverage

## v1.4.3

- fix builders properly using construction variable overrides
- expand nil construction variables to empty strings

## v1.4.2

- add `Environment#expand_path`
- expand construction variable references in builder targets and sources before invoking builder

## v1.4.1

- fix invoking a builder with no sources while a build root defined

## v1.4.0

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
- fix `Cache#mkdir_p` to handle relative paths (Issue #5)
- flush the cache to disk if a builder raises an exception (Issue #4)

## v1.3.0

- change Environment#execute() options parameter to accept the following options keys:
  - :env to pass an environment Hash to Kernel#system
  - :options to pass an options Hash to Kernel#system

## v1.2.0

- add :clone option to Environment#clone to control exactly which Environment attributes are cloned
- allow nil to be passed in to `Environment#build_root=`

## v1.1.0

- Change `Cache#up_to_date?` and `#register_build` to accept a single target
  file or an array of target file names
