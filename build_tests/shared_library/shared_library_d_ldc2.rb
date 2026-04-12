configure do
  check_d_compiler "ldc2"
end

env(echo: :command) do |env|
  env.SharedLibrary("mine", glob("src/lib/*.d"))
end
