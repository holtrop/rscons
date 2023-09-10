env "src" do |env|
  env["CPPPATH"] += glob("src/**")
  env.Program("^/src", glob("src/**/*.c"))
end
