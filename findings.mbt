///|
#derive(Eq, Debug)
pub(all) enum Severity {
  /// Breaks compilation, packaging or a navigation at runtime.
  Error
  /// Likely a bug or a device-only failure, but the project still builds.
  Warning
  /// Advice, such as unused files or package size savings.
  Info
}

///|
pub fn Severity::label(self : Severity) -> String {
  match self {
    Error => "error"
    Warning => "warning"
    Info => "info"
  }
}

///|
/// One diagnostic. `location` is a JSON path for configuration files
/// (`$.pages[1]`) and empty for source files, which use `line`/`column`
/// instead. Both are 1-based; 0 means "not applicable".
#derive(Eq, Debug)
pub(all) struct Finding {
  code : String
  severity : Severity
  file : String
  location : String
  line : Int32
  column : Int32
  detail : String
}

///|
pub fn Finding::to_json(self : Finding) -> Json {
  let fields : Map[String, Json] = {
    "code": Json::string(self.code),
    "severity": Json::string(self.severity.label()),
    "file": Json::string(self.file),
  }
  if self.location != "" {
    fields["location"] = Json::string(self.location)
  }
  if self.line > 0 {
    fields["line"] = Json::number(self.line.to_double())
    fields["column"] = Json::number(self.column.to_double())
  }
  fields["detail"] = Json::string(self.detail)
  Json::object(fields)
}

///|
/// `file:line:column` or `file $.path`, the way editors and terminals link
/// to a location.
pub fn Finding::where_(self : Finding) -> String {
  if self.line > 0 {
    "\{self.file}:\{self.line}:\{self.column}"
  } else if self.location != "" {
    "\{self.file} \{self.location}"
  } else {
    self.file
  }
}

///|
fn config_finding(
  code : String,
  severity : Severity,
  file : String,
  location : String,
  detail : String,
) -> Finding {
  { code, severity, file, location, line: 0, column: 0, detail, }
}

///|
fn source_finding(
  code : String,
  severity : Severity,
  file : String,
  position : @scan.Position,
  detail : String,
) -> Finding {
  {
    code,
    severity,
    file,
    location: "",
    line: position.line,
    column: position.column,
    detail,
  }
}

///|
/// JSON path segment for an object key, quoted so that keys containing dots
/// or brackets stay unambiguous.
fn key_path(parent : String, key : String) -> String {
  "\{parent}[\{Json::string(key).stringify()}]"
}
