# Upgrading

## v3.2.0

- Replace any calls to `env.CFile()` builder with `env.Lex()` or `env.Yacc()` as required.

## v3.0.0

- Move `build` block contents outside of `build` block and remove `build` call.
- Replace `Environment.new()` calls with `env()`.
