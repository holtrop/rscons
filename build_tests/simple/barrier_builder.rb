class B < Builder
  def run(*args)
    puts "B:#{@target}"
    true
  end
end

env do |env|
  env.add_builder(B)
  env.B("one")
  env.B("two")
  env.B("three")
  env.Barrier(:bar, %w[two three])
  env.depends("one", :bar)
end
