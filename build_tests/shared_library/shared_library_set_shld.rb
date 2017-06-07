Rscons::Environment.new do |env|
  env["CPPPATH"] << "src/lib"
  env["SHLD"] = "gcc"
  libmine = env.SharedLibrary("libmine", Dir["src/lib/*.c"])
  env.Program("test-shared.exe",
              Dir["src/*.c"],
              "LIBPATH" => %w[.],
              "LIBS" => %w[mine])
  env.build_after("test-shared.exe", libmine.to_s)
  env.Program("test-static.exe",
              Dir["src/**/*.c"])
end