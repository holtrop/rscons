Environment.new do |env|
  env.Object("simple.o", "simple.cc")
  env.process
end
