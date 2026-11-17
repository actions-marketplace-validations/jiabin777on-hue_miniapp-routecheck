///|
priv enum OutputFormat {
  JsonOutput
  TextOutput
  SarifOutput
  DotOutput
}

///|
priv struct AuditArguments {
  root : String
  format : OutputFormat
  /// Warnings also fail the run.
  strict : Bool
  options : @audit.Options
}

///|
priv enum CliArguments {
  Help
  Audit(AuditArguments)
}

///|
fn usage_message() -> String {
  let message =
    #|Usage: moon run cmd --target js -- [options] <source-root>
    #|
    #|Analyze a directory containing app.json, or a project with a
    #|project.config.json whose miniprogramRoot points at one.
    #|
    #|  --format json|text|sarif|dot  Output format (default: json).
    #|                                sarif feeds GitHub code scanning; dot is
    #|                                the package dependency graph for Graphviz.
    #|  --strict                      Treat warnings as failures.
    #|  --max-package-kb <n>          Per-package size limit (default: 2048).
    #|  --max-total-kb <n>            Total size limit (default: 20480).
    #|  -h, --help                    Show this help.
    #|  --                            Stop reading options.
    #|
    #|Exit status: 0 if clean, 1 if errors (or warnings with --strict) are
    #|found, 2 if the command cannot run.
  message
}

///|
fn parse_kib(option : String, value : String) -> Result[Int32, String] {
  let mut total = 0
  guard value != "" && value.length() <= 7 else {
    return Err("\{option} expects a positive number of KiB.")
  }
  for c in value {
    guard c >= '0' && c <= '9' else {
      return Err("\{option} expects a positive number of KiB.")
    }
    total = total * 10 + (c.to_int() - '0'.to_int())
  }
  guard total > 0 else {
    return Err("\{option} expects a positive number of KiB.")
  }
  Ok(total * 1024)
}

///|
fn parse_cli_arguments(args : Array[String]) -> Result[CliArguments, String] {
  let mut index = 0
  let mut options_enabled = true
  let mut source_root = None
  let mut format = JsonOutput
  let mut strict = false
  let mut options = @audit.Options::default()
  while index < args.length() {
    let arg = args[index]
    index = index + 1
    if options_enabled {
      if arg == "-h" || arg == "--help" {
        return Ok(Help)
      }
      if arg == "--" {
        options_enabled = false
        continue
      }
      if arg == "--strict" {
        strict = true
        continue
      }
      let mut handled = false
      for name in ["--format", "--max-package-kb", "--max-total-kb"] {
        guard arg == name || arg.has_prefix(name + "=") else { continue }
        handled = true
        let value = match arg.strip_prefix(name + "=") {
          Some(value) => value.to_owned()
          None => {
            guard index < args.length() else {
              return Err("Missing value for \{name}.")
            }
            let value = args[index]
            index = index + 1
            value
          }
        }
        match name {
          "--format" =>
            format = match value {
              "json" => JsonOutput
              "text" => TextOutput
              "sarif" => SarifOutput
              "dot" => DotOutput
              _ =>
                return Err(
                  "Unknown output format '\{value}'. Use json, text, sarif or dot.",
                )
            }
          "--max-package-kb" =>
            match parse_kib(name, value) {
              Ok(bytes) => options = { ..options, max_package_bytes: bytes, }
              Err(message) => return Err(message)
            }
          _ =>
            match parse_kib(name, value) {
              Ok(bytes) => options = { ..options, max_total_bytes: bytes, }
              Err(message) => return Err(message)
            }
        }
      }
      if handled {
        continue
      }
      if arg.has_prefix("-") {
        return Err("Unknown option '\{arg}'.")
      }
    }
    guard source_root is None && arg != "" else {
      return Err("Expected exactly one non-empty source directory.")
    }
    source_root = Some(arg)
  }
  match source_root {
    Some(root) => Ok(Audit({ root, format, strict, options, }))
    None => Err("Missing source directory.")
  }
}
