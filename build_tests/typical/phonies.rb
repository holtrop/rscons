class Custom < Rscons::Builder
  def run(options)
    print_run_message("#{name} #{target}", nil)
    true
  end
end

env do |env|
  env.add_builder(Custom)
  env.Custom("t3", :phony1)
  env.Custom(:phony1, "t2")
  env.Custom("t2", :phony2)
  env.Custom(:phony2, "t1")
  env.Custom("t1", [])
end
