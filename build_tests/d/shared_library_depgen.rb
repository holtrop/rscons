env(echo: :command) do |env|
  env.SharedLibrary("hello-d", glob("*.d"))
end
