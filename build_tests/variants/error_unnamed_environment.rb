variant "debug"
variant "release"

with_variants do
  env do |env|
    if variant("debug")
      env["CPPDEFINES"] << "DEBUG"
    else
      env["CPPDEFINES"] << "NDEBUG"
    end
    env.Program("^/prog.exe", "prog.c")
  end
end
