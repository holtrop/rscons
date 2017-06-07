class MyObject < Rscons::Builder
  def run(options)
    target, sources, cache, env, vars = options.values_at(:target, :sources, :cache, :env, :vars)
    env.run_builder(env.builders["Object"], target, sources, cache, vars)
  end
end

Rscons::Environment.new do |env|
  env.add_builder(MyObject.new)
  env.MyObject("simple.o", "simple.c")
  env.Program("simple.exe", "simple.o")
end