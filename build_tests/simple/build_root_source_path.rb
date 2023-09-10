env("e", echo: :command) do |env|
  source_file = "#{env.build_root}/src/foo.c"
  FileUtils.mkdir_p(File.dirname(source_file))
  File.open(source_file, "w") do |fh|
    fh.puts(<<-EOF)
    int main()
    {
      return 29;
    }
    EOF
  end
  env.Program("foo.exe", source_file)
end
