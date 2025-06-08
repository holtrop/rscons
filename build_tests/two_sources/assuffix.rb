env do |env|
  env["ASSUFFIX"] = %w[.ssss .sss]
  env["CFLAGS"] += %w[-S]
  env.Object("one.ssss", "one.c", "CPPFLAGS" => ["-DONE"])
  env.Object("two.sss", "two.c")
  env.Program("two_sources.exe", %w[one.ssss two.sss], "ASFLAGS" => env["ASFLAGS"] + %w[-x assembler-with-cpp])
end
