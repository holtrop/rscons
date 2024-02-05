configure do
  check_d_compiler "ldc2"
  check_lib "z"
end

env(echo: :command) do |env|
  env.Program("simple.exe", "simple.d")
end
