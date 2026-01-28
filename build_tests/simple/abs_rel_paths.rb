class B < Builder
  def run(*args)
    puts @target
    true
  end
end

env do |env|
  env.add_builder(B)
  env.B("one", File.expand_path("two"))
  env.B("two")
  env.B("three")
  env.depends("two", File.expand_path("three"))
end
