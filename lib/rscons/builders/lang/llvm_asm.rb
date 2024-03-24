Rscons::Builders::Object.register(
  command: "${LLVMAS_CMD}",
  direct_command: "${LLVMAS_CMD:direct}",
  suffix: "${LLVMAS_SUFFIX}",
  short_description: "Assembling")
Rscons::Builders::SharedObject.register(
  command: "${LLVMAS_CMD}",
  direct_command: "${LLVMAS_CMD:direct}",
  suffix: "${LLVMAS_SUFFIX}",
  short_description: "Assembling")
