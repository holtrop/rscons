class B < Builder
  def run(*args)
    puts @target
    true
  end
end

env do |env|
  env.add_builder(B)
  env.B("b")
  env.B("one")
  env.B("two")
  env.Barrier(:b)
  env.depends(:b, "two")
  env.depends("two", "b")
  env.depends("one", :b)
end
