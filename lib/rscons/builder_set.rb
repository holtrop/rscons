module Rscons
  # Class to keep track of a set of builders to be executed.
  class BuilderSet < Hash

    # Create a BuilderSet.
    #
    # @param build_dependencies [Hash]
    #   Hash mapping targets to a set of build dependencies. A builder will not
    #   be returned as ready to run if any of its dependencies are still
    #   building.
    # @param side_effects [Set]
    #   Set of side-effect files. A builder will not be returned as ready to
    #   run if any of its dependencies is a side-effect of another target that
    #   has not yet been built.
    def initialize(build_dependencies, side_effects)
      super()
      @build_dependencies = build_dependencies
      @side_effects = side_effects
    end

    # Add a builder to the BuilderSet.
    #
    # @param builder [Builder]
    #   The {Builder} that will produce the target.
    def <<(builder)
      # We allow multiple builders to be registered per target for cases like:
      #   env.Directory("dest")
      #   env.Install("dest", "bin")
      #   env.Install("dest", "share")
      self[builder.abstarget] ||= []
      self[builder.abstarget] << builder
    end

    # Return the number of remaining build steps.
    #
    # @return [Integer]
    #   The number of remaining build steps.
    def build_steps_remaining
      self.reduce(0) do |result, (target, builders)|
        result + builders.count {|b| !b.is_a?(Rscons::Builders::Barrier)}
      end
    end

    # Get the next builder that is ready to run from the BuilderSet.
    #
    # This method will remove the builder from the BuilderSet.
    #
    # @param targets_still_building [Array<String>]
    #   Targets that are not finished building. This is used to avoid returning
    #   a builder as available to run if it depends on one of the targets that
    #   are still building as a source.
    #
    # @return [nil, Builder]
    #   The next builder to run.
    def get_next_builder_to_run(targets_still_building)
      to_build = self.find do |target, builders|
        deps = builders.first.abssources + (@build_dependencies[target] || []).to_a
        # All dependencies must have been built for this target to be ready to
        # build.
        deps.all? do |dep|
          !(targets_still_building.include?(dep) ||
            self.include?(dep) ||
            @side_effects.include?(dep))
        end
      end

      if to_build
        target, builders = *to_build
        builder = builders.first
        if builders.size > 1
          builders.slice!(0)
        else
          self.delete(target)
        end
        return builder
      end

      # If there is a builder to run, and nothing is still building, but we did
      # not find a builder to run above, then there might be a circular
      # dependency introduced by the user.
      if (self.size > 0) and targets_still_building.empty?
        raise "Could not find a runnable builder. Possible circular dependency for #{self.first[1].first.target}"
      end
    end

  end
end
