configure do
  check_d_compiler "my-d-compiler"
end

env(echo: :command) do |env|
  env.SharedLibrary("mine", glob("src/lib/*.d"))
end
