///|
/// The result of analyzing one mini program.
pub struct Report {
  findings : Array[Finding]
  packages : Array[PackageStats]
  edges : Array[Edge]
  files : Int32
}

///|
pub fn Report::count(self : Report, severity : Severity) -> Int32 {
  self.findings.filter(fn(f) { f.severity == severity }).length()
}

///|
/// Converts the JSON issues of `audit_manifest` into findings on app.json.
fn manifest_findings(issues : Json) -> Array[Finding] {
  guard issues is Array(items) else { return [] }
  let out = []
  for item in items {
    if item is Object(fields) &&
      fields.get("code") is Some(String(code)) &&
      fields.get("location") is Some(String(location)) &&
      fields.get("detail") is Some(String(detail)) {
      out.push(config_finding(code, Error, "app.json", location, detail))
    }
  }
  out
}

///|
/// Analyzes a mini program: validates `app.json`, builds the dependency
/// graph of every page, component, script, template, style and asset,
/// then applies the package boundary, navigation, template, cycle and size
/// rules to it.
pub fn analyze(
  project : Project,
  options~ : Options = Options::default(),
) -> Report {
  let empty = fn(findings) {
    { findings, packages: [], edges: [], files: project.sizes.length(), }
  }
  guard project.exists("app.json") else {
    return empty([
      config_finding(
        "missing-app-json",
        Error,
        "app.json",
        "",
        "No app.json in the mini program root.",
      ),
    ])
  }
  guard (project.reader)("app.json") is Some(content) else {
    return empty([
      config_finding(
        "unreadable-file",
        Error,
        "app.json",
        "",
        "The file could not be read as UTF-8 text.",
      ),
    ])
  }
  let files = project.sizes.keys().collect()
  let findings = manifest_findings(audit_manifest(content, files))
  let parsed = Some(@json.parse(content, reject_duplicate_keys=true)) catch {
    _ => None
  }
  guard parsed is Some(Object(manifest)) else { return empty(findings) }
  let analyzer : Analyzer = {
    project,
    findings,
    packages: [],
    routes: Map([]),
    tab_pages: Map([]),
    edges: [],
    units: Map([]),
    files_seen: Map([]),
    wxml: Map([]),
    navigations: [],
    queue: [],
    extended_prefixes: [],
  }
  analyzer.load_manifest(manifest)
  analyzer.seed(manifest)
  analyzer.run()
  analyzer.check_templates()
  analyzer.check_unused_components()
  analyzer.check_boundaries()
  analyzer.check_navigation()
  analyzer.check_require_cycles()
  let packages = analyzer.check_sizes(options)
  // Name the files the developer wrote, not their compiled outputs.
  let source = fn(path) { project.source_name(path) }
  {
    findings: analyzer.findings.map(fn(f) { { ..f, file: source(f.file), } }),
    packages,
    edges: analyzer.edges.map(fn(e) {
      { ..e, from: source(e.from), to: source(e.to), file: source(e.file), }
    }),
    files: project.sizes.length(),
  }
}

///|
fn PackageStats::to_json(self : PackageStats) -> Json {
  {
    "name": Json::string(self.name),
    "root": Json::string(self.root),
    "independent": Json::boolean(self.independent),
    "files": Json::number(self.files.to_double()),
    "bytes": Json::number(self.bytes.to_double()),
    "movableBytes": Json::number(self.movable_bytes.to_double()),
  }
}

///|
pub fn Report::to_json(self : Report) -> Json {
  {
    "summary": {
      "errors": Json::number(self.count(Error).to_double()),
      "warnings": Json::number(self.count(Warning).to_double()),
      "infos": Json::number(self.count(Info).to_double()),
      "files": Json::number(self.files.to_double()),
      "edges": Json::number(
        self.edges.filter(fn(e) { !(e.kind is PageFile) }).length().to_double(),
      ),
    },
    "packages": Json::array(self.packages.map(fn(p) { p.to_json() })),
    "findings": Json::array(self.findings.map(fn(f) { f.to_json() })),
  }
}

///|
fn kib(bytes : Int32) -> String {
  let tenths = (bytes * 10 + 512) / 1024
  "\{tenths / 10}.\{tenths % 10} KiB"
}

///|
fn pad(text : String, width : Int32) -> String {
  if text.length() >= width {
    text
  } else {
    text + " ".repeat(width - text.length())
  }
}

///|
/// Human-readable report: one line per finding, then package sizes.
pub fn Report::to_text(
  self : Report,
  options~ : Options = Options::default(),
) -> String {
  let out = StringBuilder()
  for f in self.findings {
    out.write_string(
      "\{pad(f.severity.label(), 7)} \{f.where_()}  [\{f.code}] \{f.detail}\n",
    )
  }
  if self.findings.is_empty() {
    out.write_string("No issues found.\n")
  }
  if !self.packages.is_empty() {
    out.write_string("\nPackages:\n")
    let width = self.packages.fold(init=4, fn(w, p) {
      max_int(w, p.name.length())
    })
    for p in self.packages {
      let name = if p.root == "" { "main" } else { p.name }
      let notes = []
      if p.independent {
        notes.push("independent")
      }
      if p.movable_bytes > 0 {
        notes.push("\{kib(p.movable_bytes)} movable from main")
      }
      let suffix = if notes.is_empty() {
        ""
      } else {
        "  (" + notes.join(", ") + ")"
      }
      out.write_string(
        "  \{pad(name, width)}  \{pad(kib(p.bytes), 11)} of \{kib(options.max_package_bytes)}  \{p.files} files\{suffix}\n",
      )
    }
  }
  out.write_string(
    "\n\{self.count(Error)} errors, \{self.count(Warning)} warnings, \{self.count(Info)} notes.\n",
  )
  out.to_string()
}

///|
/// SARIF 2.1.0, the format GitHub code scanning and most CI dashboards
/// ingest. Paths are relative to the mini program root.
pub fn Report::to_sarif(self : Report, root_uri~ : String = "") -> Json {
  let rules : Array[Json] = []
  let rule_index : Map[String, Int32] = Map([])
  let results : Array[Json] = []
  for f in self.findings {
    if !rule_index.contains(f.code) {
      rule_index[f.code] = rules.length()
      rules.push({ "id": Json::string(f.code) })
    }
    let physical : Map[String, Json] = {
      "artifactLocation": { "uri": Json::string(root_uri + f.file) },
    }
    if f.line > 0 {
      physical["region"] = {
        "startLine": Json::number(f.line.to_double()),
        "startColumn": Json::number(f.column.to_double()),
      }
    }
    let location : Map[String, Json] = {
      "physicalLocation": Json::object(physical),
    }
    if f.location != "" {
      location["logicalLocations"] = [
        { "fullyQualifiedName": Json::string(f.location), "kind": "member" },
      ]
    }
    results.push({
      "ruleId": Json::string(f.code),
      "ruleIndex": Json::number(rule_index[f.code].to_double()),
      "level": Json::string(
        match f.severity {
          Error => "error"
          Warning => "warning"
          Info => "note"
        },
      ),
      "message": { "text": Json::string(f.detail) },
      "locations": [Json::object(location)],
    })
  }
  {
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    "version": "2.1.0",
    "runs": [
      {
        "tool": {
          "driver": {
            "name": "miniapp-routecheck",
            "informationUri": "https://github.com/jiabin777on-hue/miniapp-routecheck",
            "rules": Json::array(rules),
          },
        },
        "results": Json::array(results),
      },
    ],
  }
}

///|
fn dot_id(text : String) -> String {
  Json::string(text).stringify()
}

///|
/// Graphviz DOT of pages, components and the files they depend on, with
/// one cluster per package. Edges that break a package rule are red.
pub fn Report::to_dot(self : Report) -> String {
  let violations : Map[String, Unit] = Map([])
  for f in self.findings {
    if f.line > 0 || f.location != "" {
      violations["\{f.file}:\{f.line}:\{f.column}:\{f.location}"] = ()
    }
  }
  let package_of = fn(node : String) -> Int32 {
    let mut best = -1
    for index, p in self.packages {
      if is_under(node, p.root) &&
        (best < 0 || p.root.length() > self.packages[best].root.length()) {
        best = index
      }
    }
    max_int(best, 0)
  }
  let nodes : Map[String, Unit] = Map([])
  for e in self.edges {
    if !(e.kind is PageFile) {
      nodes[e.from] = ()
      nodes[e.to] = ()
    }
  }
  let out = StringBuilder()
  out.write_string(
    "digraph miniapp {\n  rankdir=LR;\n  node [shape=box, fontname=\"Helvetica\", fontsize=10];\n",
  )
  for index, p in self.packages {
    let label = if p.root == "" { "main package" } else { p.name }
    out.write_string(
      "  subgraph cluster_\{index} {\n    label=\{dot_id(label)};\n",
    )
    for node, _ in nodes {
      if package_of(node) == index {
        out.write_string("    \{dot_id(node)};\n")
      }
    }
    out.write_string("  }\n")
  }
  for e in self.edges {
    if e.kind is PageFile {
      continue
    }
    let key = "\{e.file}:\{e.line}:\{e.column}:\{e.location}"
    let style = if violations.contains(key) &&
      package_of(e.from) != package_of(e.to) {
      ", color=red, fontcolor=red"
    } else if e.kind.is_async() {
      ", style=dashed"
    } else {
      ""
    }
    out.write_string(
      "  \{dot_id(e.from)} -> \{dot_id(e.to)} [label=\{dot_id(e.kind.label())}\{style}];\n",
    )
  }
  out.write_string("}\n")
  out.to_string()
}
