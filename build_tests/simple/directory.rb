build do
  Rscons::Environment.new do |env|
    env.Directory("teh_dir")
  end
end
