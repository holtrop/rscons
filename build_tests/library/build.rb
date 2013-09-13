Rscons::Environment.new(echo: :command) do |env|
  env.Program('library', ['lib.a', 'three.c'])
  env.Library("lib.a", ['one.c', 'two.c'], 'CPPFLAGS' => ['-Dmake_lib'])
end
