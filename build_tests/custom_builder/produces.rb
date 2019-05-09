build do
  Environment.new do |env|
    env["build_root"] = env.build_root
    env["inc_h"] = "inc.h"

    env.Copy("copy_inc.h", "${inc_h}")
    env.depends("${build_root}/program.o", "${inc_h}")
    env.Program("program.exe", ["program.c", "inc.c"])

    inc_c = env.Command("inc.c",
                        [],
                        "CMD" => %w[ruby gen.rb ${_TARGET}],
                        "CMD_DESC" => "Generating")
    inc_c.produces("inc.h")
  end
end
