env do |env|
  env["PROGSUFFIX"] = ".out"
  env.Program("simple", Dir["*.c"])
end
