build do
  env1 = Environment.new(echo: :command) do |env|
    env['CFLAGS'] = '-O2'
    env.add_build_hook do |builder|
      builder.vars['CPPFLAGS'] = '-DSTRING="Hello"'
    end
    env.add_post_build_hook do |builder|
      $stdout.puts "post #{builder.target}"
    end
    env.Program('program.exe', Dir['src/*.c'])
  end

  env2 = env1.clone do |env|
    env.Program('program2.exe', Dir['src/*.c'])
  end
end
