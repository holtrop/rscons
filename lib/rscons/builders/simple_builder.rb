module Rscons
  module Builders
    # A Generic builder which has its operation is defined at instantiation.
    class SimpleBuilder < Builder

      # @return [String]
      #   User-provided builder name.
      attr_reader :name

      # Create an instance of the Builder to build a target.
      #
      # @param name [String]
      #   User-provided builder name.
      # @param options [Hash]
      #   Options.
      # @option options [String] :target
      #   Target file name.
      # @option options [Array<String>] :sources
      #   Source file name(s).
      # @option options [Environment] :env
      #   The Environment executing the builder.
      # @option options [Hash,VarSet] :vars
      #   Extra construction variables.
      # @param run_proc [Proc]
      #   A Proc to execute when the builder runs. The provided block must
      #   have the same signature as {Builder#run}.
      def initialize(name, options, &run_proc)
        @name = name
        super(options)
        @run_proc = run_proc
      end

      # Run the builder to produce a build target.
      #
      # Method signature described by {Builder#run}.
      def run(*args)
        instance_exec(*args, &@run_proc)
      end

    end
  end
end
