env do |env|
  env.add_builder(:MyBuilder) do |options|
    "hi"
  end
  env.MyBuilder("foo")
end
