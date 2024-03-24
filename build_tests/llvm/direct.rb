configure do
  check_c_compiler "clang"
end

env do |env|
  env["LLVMAS_FLAGS"] += %w[-Wno-override-module]
  env.Program("llvmtest.exe", %w[one.ll two.ll main2.c], direct: true)
end
