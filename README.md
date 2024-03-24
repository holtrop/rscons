# Rscons

![rscons logo](img/rscons_logo_1000.png)

Rscons (https://github.com/holtrop/rscons) is an open-source build system
for developers.
It supports the following features:

  * multi-threaded job execution
  * auto-configuration
  * built-in builders for several common operations
  * out-of-the-box support for Assembly, C, C++, D, and LLVM
  * extensibility for other languages or custom builders
  * compatible with Windows, Linux, OS X, and FreeBSD
  * colorized output with build progress
  * build hooks
  * user-defined tasks with dependencies and custom parameters
  * build variants

At its core, Rscons is mainly an engine to:

  * determine the proper order to perform build steps,
  * determine whether each build target is up to date or in need of rebuild, and
  * schedule those build steps across multiple threads as efficiently as possible.

Along the way, Rscons provides a concise syntax for specifying common types of
build steps, but also provides an extensible framework for performing
custom build operations as well.

Rscons takes inspiration from:

  * [SCons](https://scons.org/)
  * [waf](https://waf.io/)
  * [rake](https://github.com/ruby/rake)
  * [CMake](https://cmake.org/)
  * [Autoconf](https://www.gnu.org/software/autoconf/)

Rscons is written in Ruby.
The only requirement to run Rscons is that the system has a Ruby interpreter
installed.

See [https://holtrop.github.io/rscons/index.html](https://holtrop.github.io/rscons/index.html) for User Guide and Installation instructions.
