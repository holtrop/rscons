configure do
  check_d_compiler "ldc2"
end

env(echo: :command) do |env|
  env.SharedLibrary("hello-d", glob("*.d"))
end
