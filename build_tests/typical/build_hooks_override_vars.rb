env(echo: :command) do |env|
  env.append('CPPPATH' => glob('src/**'))
  env.add_build_hook do |builder|
    if builder.name == "Object" && builder.sources.first =~ %r{one\.c}
      builder.vars["CFLAGS"] << "-O1"
    elsif builder.name == "Object" && builder.target =~ %r{two\.o}
      new_vars = builder.vars.clone
      new_vars["CFLAGS"] << "-O2"
      builder.vars = new_vars
    end
  end
  env.Object('one.o', 'src/one/one.c')
  env.Object('two.o', 'src/two/two.c')
end
