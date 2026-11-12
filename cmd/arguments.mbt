///|
priv enum OutputFormat {
  JsonOutput
  TextOutput
}

///|
priv enum CliArguments {
  Help
  Audit(String, OutputFormat)
}

///|
fn usage_message() -> String {
  let message =
    #|Usage: moon run cmd --target js -- [--format json|text] <source-root>
    #|
    #|Audit a directory containing app.json or a project.config.json with miniprogramRoot.
    #|  --format json|text  Set the output format (default: json).
    #|  -h, --help          Show this help.
    #|  --                 Stop reading options.
    #|
    #|Exit status: 0 if clean, 1 if issues are found, 2 if the command cannot run.
  message
}

///|
fn parse_cli_arguments(args : Array[String]) -> Result[CliArguments, String] {
  let mut index = 0
  let mut options_enabled = true
  let mut source_root = None
  let mut format = JsonOutput
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
      if arg == "--format" || arg.has_prefix("--format=") {
        let value = match arg.strip_prefix("--format=") {
          Some(value) => value.to_owned()
          None => {
            guard index < args.length() else {
              return Err("Missing value for --format.")
            }
            let value = args[index]
            index = index + 1
            value
          }
        }
        format = match value {
          "json" => JsonOutput
          "text" => TextOutput
          _ => return Err("Unknown output format '\{value}'. Use json or text.")
        }
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
    Some(root) => Ok(Audit(root, format))
    None => Err("Missing source directory.")
  }
}
