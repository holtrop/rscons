class TestBuilder < Rscons::Builder
  def run(options)
    command = Rscons::VarSet.new("A" => "a", "B" => "b")
    unless @cache.up_to_date?(@target, command, @sources, @env)
      File.open(@target, "w") do |fh|
        fh.puts("hi")
      end
      msg = "#{name} #{@target}"
      print_run_message(msg, msg)
      @cache.register_build(@target, command, @sources, @env)
    end
    true
  end
end

env do |env|
  env.add_builder(TestBuilder)
  env.TestBuilder("foo")
end
