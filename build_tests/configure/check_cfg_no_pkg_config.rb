ENV["PATH"] = ""

configure do
  check_cfg package: "mypackage"
end
