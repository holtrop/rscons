module Rscons
  module Builders
    # The Barrier builder does not perform any action. It exists as a builder
    # on which to place dependencies to ensure that each of its sources are
    # built before any build targets which depend on the barrier build target.
    class Barrier < Builder

      # Run the builder.
      def run(options)
        true
      end

    end
  end
end
