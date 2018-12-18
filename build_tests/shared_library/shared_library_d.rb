build do
  Rscons::Environment.new do |env|
    env["CPPPATH"] << "src/lib"
    libmine = env.SharedLibrary("mine", Rscons.glob("src/lib/*.d"))
    env.Program("test-shared.exe",
                Rscons.glob("src/*.c"),
                "LIBPATH" => %w[.],
                "LIBS" => %w[mine])
    env.build_after("test-shared.exe", libmine.to_s)
  end
end
