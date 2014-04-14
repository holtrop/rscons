require "digest/md5"
require "fileutils"
require "json"
require "set"
require "rscons/version"

module Rscons
  # The Cache class keeps track of file checksums, build target commands and
  # dependencies in a JSON file which persists from one invocation to the next.
  # Example cache:
  #   {
  #     "version" => "1.2.3",
  #     "targets" => {
  #       "program" => {
  #         "checksum" => "A1B2C3D4",
  #         "command" => ["gcc", "-o", "program", "program.o"],
  #         "deps" => [
  #           {
  #             "fname" => "program.o",
  #             "checksum" => "87654321",
  #           },
  #         ],
  #         "user_deps" => [
  #           {
  #             "fname" => "lscript.ld",
  #             "checksum" => "77551133",
  #           },
  #         ],
  #       },
  #       "program.o" => {
  #         "checksum" => "87654321",
  #         "command" => ["gcc", "-c", "-o", "program.o", "program.c"],
  #         "deps" => [
  #           {
  #             "fname" => "program.c",
  #             "checksum" => "456789ABC",
  #           },
  #           {
  #             "fname" => "program.h",
  #             "checksum" => "7979764643",
  #           },
  #         ],
  #         "user_deps" => [],
  #       }
  #     },
  #     "directories" => {
  #       "build" => true,
  #       "build/one" => true,
  #       "build/two" => true,
  #     },
  #   }
  class Cache
    #### Constants

    # Name of the file to store cache information in
    CACHE_FILE = ".rsconscache"

    #### Class Methods

    # Remove the cache file
    def self.clear
      FileUtils.rm_f(CACHE_FILE)
    end

    #### Instance Methods

    # Create a Cache object and load in the previous contents from the cache
    # file.
    def initialize
      @cache = JSON.load(File.read(CACHE_FILE)) rescue {}
      unless @cache.is_a?(Hash)
        $stderr.puts "Warning: #{CACHE_FILE} was corrupt. Contents:\n#{@cache.inspect}"
        @cache = {}
      end
      @cache["targets"] ||= {}
      @cache["directories"] ||= {}
      @lookup_checksums = {}
    end

    # Write the cache to disk to be loaded next time.
    def write
      @cache["version"] = VERSION
      File.open(CACHE_FILE, "w") do |fh|
        fh.puts(JSON.dump(@cache))
      end
    end

    # Check if target(s) are up to date
    # @param targets [String, Array] The name(s) of the target file(s).
    # @param command [String, Array] The command used to build the target.
    # @param deps [Array] List of the target's dependency files.
    # @param env [Environment] The Rscons::Environment.
    # @param options [Hash] Optional options.
    # @option options [Boolean] :strict_deps
    #   Only consider a target up to date if its list of dependencies is
    #   exactly equal (including order) to the cached list of dependencies
    # @return [Boolean]
    #   True value if the targets are all up to date, meaning that,
    #   for each target:
    #   - the target exists on disk
    #   - the cache has information for the target
    #   - the target's checksum matches its checksum when it was last built
    #   - the command used to build the target is the same as last time
    #   - all dependencies listed are also listed in the cache, or, if
    #     :strict_deps was given in options, the list of dependencies is
    #     exactly equal to those cached
    #   - each cached dependency file's current checksum matches the checksum
    #     stored in the cache file
    def up_to_date?(targets, command, deps, env, options = {})
      Array(targets).each do |target|
        # target file must exist on disk
        return false unless File.exists?(target)

        # target must be registered in the cache
        return false unless @cache["targets"].has_key?(target)

        # target must have the same checksum as when it was built last
        return false unless @cache["targets"][target]["checksum"] == lookup_checksum(target)

        # command used to build target must be identical
        return false unless @cache["targets"][target]["command"] == command

        cached_deps = @cache["targets"][target]["deps"] || []
        cached_deps_fnames = cached_deps.map { |dc| dc["fname"] }
        if options[:strict_deps]
          # depedencies passed in must exactly equal those in the cache
          return false unless deps == cached_deps_fnames
        else
          # all dependencies passed in must exist in cache (but cache may have more)
          return false unless (Set.new(deps) - Set.new(cached_deps_fnames)).empty?
        end

        # set of user dependencies must match
        user_deps = env.get_user_deps(target) || []
        cached_user_deps = @cache["targets"][target]["user_deps"] || []
        cached_user_deps_fnames = cached_user_deps.map { |dc| dc["fname"] }
        return false unless user_deps == cached_user_deps_fnames

        # all cached dependencies must have their checksums match
        (cached_deps + cached_user_deps).each do |dep_cache|
          return false unless dep_cache["checksum"] == lookup_checksum(dep_cache["fname"])
        end
      end

      true
    end

    # Store cache information about target(s) built by a builder
    # @param targets [String, Array] The name of the target(s) built.
    # @param command [String, Array] The command used to build the target.
    # @param deps [Array] List of dependencies for the target.
    # @param env [Environment] The {Rscons::Environment}.
    def register_build(targets, command, deps, env)
      Array(targets).each do |target|
        @cache["targets"][target.encode(__ENCODING__)] = {
          "command" => command,
          "checksum" => calculate_checksum(target),
          "deps" => deps.map do |dep|
            {
              "fname" => dep.encode(__ENCODING__),
              "checksum" => lookup_checksum(dep),
            }
          end,
          "user_deps" => (env.get_user_deps(target) || []).map do |dep|
            {
              "fname" => dep.encode(__ENCODING__),
              "checksum" => lookup_checksum(dep),
            }
          end,
        }
      end
    end

    # Return a list of targets that have been built
    def targets
      @cache["targets"].keys
    end

    # Make any needed directories and record the ones that are created for
    # removal upon a "clean" operation.
    def mkdir_p(path)
      parts = path.split(/[\\\/]/)
      parts.each_index do |i|
        subpath = File.join(*parts[0, i + 1]).encode(__ENCODING__)
        unless File.exists?(subpath)
          FileUtils.mkdir(subpath)
          @cache["directories"][subpath] = true
        end
      end
    end

    # Return a list of directories which were created as a part of the build
    def directories
      @cache["directories"].keys
    end

    # Private Instance Methods
    private

    # Return a file's checksum, or the previously calculated checksum for
    # the same file
    # @param file [String] The file name.
    def lookup_checksum(file)
      @lookup_checksums[file] || calculate_checksum(file)
    end

    # Calculate and return a file's checksum
    # @param file [String] The file name.
    def calculate_checksum(file)
      @lookup_checksums[file] = Digest::MD5.hexdigest(File.read(file, mode: "rb")).encode(__ENCODING__) rescue ""
    end
  end
end
