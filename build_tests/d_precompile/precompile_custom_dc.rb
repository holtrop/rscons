configure do
  check_d_compiler "my-d-compiler"
end

env(echo: :command) do |env|
  env["D_IMPORT_PATH"] << "src"
  env.Program("hello-d.exe", glob("src/*.d"))
end
