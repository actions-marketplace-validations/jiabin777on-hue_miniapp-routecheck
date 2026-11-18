// Plugins, workers and entranceDeclare

///|
/// The `subpackages` (or `subPackages`) entries with their JSON path.
fn subpackage_entries(
  manifest : Map[String, Json],
) -> Array[(String, Map[String, Json])] {
  let (key, value) = match
    (manifest.get("subpackages"), manifest.get("subPackages")) {
    (Some(value), _) => ("subpackages", value)
    (None, Some(value)) => ("subPackages", value)
    (None, None) => return []
  }
  guard value is Array(entries) else { return [] }
  let out = []
  for index, entry in entries {
    if entry is Object(fields) {
      out.push(("$.\{key}[\{index}]", fields))
    }
  }
  out
}

///|
fn is_nonempty_string(value : Json?) -> Bool {
  value is Some(String(text)) && text.trim() != ""
}

///|
/// Checks the `plugins` objects of app.json and of each subpackage. Each
/// entry needs a `version` and a `provider` AppID, and the same plugin
/// cannot be used by more than one subpackage.
fn check_plugin_declarations(
  manifest : Map[String, Json],
  issues : Array[Json],
) -> Unit {
  let declarations : Array[(String, Json, Bool)] = []
  if manifest.get("plugins") is Some(value) {
    declarations.push(("$.plugins", value, false))
  }
  for entry in subpackage_entries(manifest) {
    let (location, fields) = entry
    if fields.get("plugins") is Some(value) {
      declarations.push(("\{location}.plugins", value, true))
    }
  }
  // provider AppID -> location of the subpackage entry that uses it
  let subpackage_providers : Map[String, String] = Map([])
  for declaration in declarations {
    let (location, value, in_subpackage) = declaration
    guard value is Object(plugins) else {
      finding(
        issues, "invalid-plugins", location, "Expected an object keyed by plugin alias.",
      )
      continue
    }
    for plugin_name, plugin in plugins {
      let entry_location = key_path(location, plugin_name)
      guard plugin is Object(fields) else {
        finding(
          issues, "invalid-plugin", entry_location, "Expected an object with version and provider.",
        )
        continue
      }
      for field in ["version", "provider"] {
        if !is_nonempty_string(fields.get(field)) {
          finding(
            issues,
            "invalid-plugin",
            "\{entry_location}.\{field}",
            "Expected a non-empty string.",
          )
        }
      }
      guard in_subpackage && fields.get("provider") is Some(String(provider)) else {
        continue
      }
      match subpackage_providers.get(provider) {
        Some(previous) =>
          finding(
            issues,
            "duplicate-plugin",
            "\{entry_location}.provider",
            "Plugin \{provider} is also used by \{previous}; one plugin cannot be used by several subpackages.",
          )
        None => subpackage_providers[provider] = location
      }
    }
  }
}

///|
/// The worker directory named by `workers`: a string, or an object with
/// `path` (and `isSubpackage`). Trailing slashes are dropped.
fn workers_directory(manifest : Map[String, Json]) -> String? {
  let path = match manifest.get("workers") {
    Some(String(path)) => path
    Some(Object(fields)) =>
      match fields.get("path") {
        Some(String(path)) => path
        _ => return None
      }
    _ => return None
  }
  let mut trimmed = path
  while trimmed.strip_suffix("/") is Some(rest) {
    trimmed = rest.to_owned()
  }
  if trimmed.strip_prefix("/") is Some(rest) {
    trimmed = rest.to_owned()
  }
  if is_safe_path(trimmed) {
    Some(trimmed)
  } else {
    None
  }
}

///|
fn check_workers_declaration(
  manifest : Map[String, Json],
  issues : Array[Json],
) -> Unit {
  guard manifest.get("workers") is Some(value) else { return }
  if value is Object(fields) &&
    fields.get("isSubpackage") is Some(flag) &&
    !(flag is (True | False)) {
    finding(
      issues, "invalid-workers", "$.workers.isSubpackage", "Expected true or false.",
    )
  }
  if workers_directory(manifest) is None {
    let location = if value is Object(_) {
      "$.workers.path"
    } else {
      "$.workers"
    }
    finding(
      issues, "invalid-workers", location, "Expected a portable relative directory path, as a string or { \"path\": ... }.",
    )
  }
}

///|
/// `entranceDeclare.locationMessage` opens a page from a chat location
/// message, so its `path` must be a declared page.
fn check_entrance_declare(
  manifest : Map[String, Json],
  routes : Map[String, Route],
  issues : Array[Json],
) -> Unit {
  guard manifest.get("entranceDeclare") is Some(value) else { return }
  guard value is Object(entrances) else {
    finding(
      issues, "invalid-entrance-declare", "$.entranceDeclare", "Expected an object.",
    )
    return
  }
  guard entrances.get("locationMessage") is Some(message) else { return }
  let location = "$.entranceDeclare.locationMessage"
  guard message is Object(fields) else {
    finding(
      issues, "invalid-entrance-declare", location, "Expected an object with path and query.",
    )
    return
  }
  match fields.get("path") {
    Some(String(path)) if routes.contains(path) => ()
    Some(String(path)) =>
      finding(
        issues,
        "unknown-entrance-route",
        "\{location}.path",
        "\{path} is not a page declared in app.json (write the route without a leading / or query).",
      )
    _ =>
      finding(
        issues,
        "invalid-entrance-declare",
        "\{location}.path",
        "Expected a page path string.",
      )
  }
  match fields.get("query") {
    None | Some(String(_)) => ()
    Some(_) =>
      finding(
        issues,
        "invalid-entrance-declare",
        "\{location}.query",
        "Expected a query string such as \"foo=bar\".",
      )
  }
}

///|
/// A reference to a plugin: a `plugin://` component or page, or a
/// `requirePlugin` call.
priv struct PluginUse {
  name : String
  what : String
  file : String
  location : String
  position : @scan.Position?
  /// A component with a `componentPlaceholder`, which may load a plugin
  /// from another package asynchronously.
  async_component : Bool
}

///|
priv struct PluginDeclaration {
  name : String
  provider : String
  package_index : Int32
  location : String
}

///|
/// The plugin name in `plugin://name/component`.
fn plugin_name_of(url : String) -> String? {
  guard url.strip_prefix("plugin://") is Some(rest) else { return None }
  let name = match rest.find("/") {
    Some(index) => rest[:index].to_owned()
    None => rest.to_owned()
  }
  if name == "" {
    None
  } else {
    Some(name)
  }
}

///|
/// Records the plugins declared by app.json and by each subpackage, and
/// the worker directory.
fn Analyzer::load_features(
  self : Analyzer,
  manifest : Map[String, Json],
) -> Unit {
  let add = fn(location : String, value : Json?, package_index : Int32) {
    guard value is Some(Object(plugins)) else { return }
    for name, plugin in plugins {
      let provider = match plugin {
        Object(fields) =>
          match fields.get("provider") {
            Some(String(provider)) => provider
            _ => ""
          }
        _ => ""
      }
      self.plugins.push({
        name,
        provider,
        package_index,
        location: key_path(location, name),
      })
    }
  }
  add("$.plugins", manifest.get("plugins"), 0)
  for entry in subpackage_entries(manifest) {
    let (location, fields) = entry
    guard fields.get("root") is Some(String(raw_root)) else { continue }
    let root = match raw_root.strip_suffix("/") {
      Some(trimmed) => trimmed.to_owned()
      None => raw_root
    }
    for index, pkg in self.packages {
      if index > 0 && pkg.root == root {
        add("\{location}.plugins", fields.get("plugins"), index)
        break
      }
    }
  }
  self.workers_root = workers_directory(manifest)
}

///|
/// Every JavaScript file in the worker directory is bundled into the
/// worker, so each one is an entry point.
fn Analyzer::seed_workers(self : Analyzer) -> Unit {
  guard self.workers_root is Some(root) else { return }
  let files = self.project.sizes.keys().collect()
  files.sort()
  for path in files {
    if is_under(path, root) && extension(path) == ".js" {
      self.enqueue_file(path)
    }
  }
}

///|
fn Analyzer::in_workers(self : Analyzer, path : String) -> Bool {
  self.workers_root is Some(root) && is_under(path, root)
}

///|
fn Analyzer::plugin_finding(
  self : Analyzer,
  use_ : PluginUse,
  code : String,
  severity : Severity,
  detail : String,
) -> Unit {
  match use_.position {
    Some(position) =>
      self.add(source_finding(code, severity, use_.file, position, detail))
    None =>
      self.add(config_finding(code, severity, use_.file, use_.location, detail))
  }
}

///|
/// A plugin must be declared before use. One declared by a subpackage is
/// only available inside that subpackage, except to components loaded
/// asynchronously through `componentPlaceholder`.
fn Analyzer::check_plugins(self : Analyzer) -> Unit {
  let uses = self.plugin_uses.copy()
  for site in self.navigations {
    if plugin_name_of(site.url) is Some(name) {
      uses.push({
        name,
        what: "plugin page \{site.url}",
        file: site.file,
        location: "",
        position: Some(site.position),
        async_component: false,
      })
    }
  }
  let used : Map[String, Unit] = Map([])
  for use_ in uses {
    // requirePlugin also accepts the plugin's AppID (base library 2.14.0).
    let declarations = self.plugins.filter(fn(d) {
      d.name == use_.name || (d.provider != "" && d.provider == use_.name)
    })
    for declaration in declarations {
      used[declaration.location] = ()
    }
    if declarations.is_empty() {
      self.plugin_finding(
        use_,
        "unknown-plugin",
        Error,
        "\{use_.what} uses plugin '\{use_.name}', which is not declared in the plugins of app.json or of any subpackage.",
      )
      continue
    }
    let owner = self.owner(use_.file)
    if use_.async_component ||
      declarations
      .iter()
      .any(fn(d) { d.package_index == 0 || d.package_index == owner }) {
      continue
    }
    let declared_in = declarations
      .map(fn(d) { self.package_label(d.package_index) })
      .join(", ")
    self.plugin_finding(
      use_,
      "plugin-not-in-package",
      Error,
      "Plugin '\{use_.name}' is declared by \{declared_in} and can only be used there, not from \{self.package_label(owner)}.",
    )
  }
  for declaration in self.plugins {
    if !used.contains(declaration.location) {
      self.add(
        config_finding(
          "unused-plugin",
          Info,
          "app.json",
          declaration.location,
          "Nothing references plugin '\{declaration.name}' through plugin://, requirePlugin or a plugin page; it is still downloaded with \{self.package_label(declaration.package_index)}.",
        ),
      )
    }
  }
}

///|
/// The worker directory holds only JavaScript, its code can only require
/// files inside it, and `wx.createWorker` must name a file in it.
fn Analyzer::check_workers(self : Analyzer) -> Unit {
  match self.workers_root {
    None => ()
    Some(root) => {
      let mut any = false
      for path, _ in self.project.sizes {
        guard is_under(path, root) else { continue }
        any = true
        if extension(path) != ".js" && !is_project_file(path) {
          self.add(
            config_finding(
              "invalid-worker-file",
              Warning,
              path,
              "",
              "The worker directory \{root} can only contain JavaScript; move other files outside it.",
            ),
          )
        }
      }
      if !any {
        self.add(
          config_finding(
            "missing-workers-directory",
            Error,
            "app.json",
            "$.workers",
            "The worker directory \{root} has no files.",
          ),
        )
      }
      for edge in self.edges {
        if edge.kind is PageFile ||
          !is_under(edge.from, root) ||
          is_under(edge.to, root) {
          continue
        }
        self.edge_finding(
          edge,
          "worker-dependency-outside-directory",
          "Worker code can only require files inside \{root}, not \{edge.to}.",
        )
      }
    }
  }
  for call in self.worker_calls {
    let (file, argument, position) = call
    let target = match argument.strip_prefix("/") {
      Some(rest) => rest.to_owned()
      None => argument
    }
    guard normalize_path(target) is Some(path) && path != "" else {
      self.add(
        source_finding(
          "unresolved-worker",
          Error,
          file,
          position,
          "wx.createWorker('\{argument}') does not name a file inside the mini program.",
        ),
      )
      continue
    }
    let inside = match self.workers_root {
      Some(root) => is_under(path, root)
      None => false
    }
    if !inside {
      let detail = match self.workers_root {
        Some(root) => "\{path} is outside the worker directory \{root}."
        None => "app.json declares no workers directory for \{path}."
      }
      self.add(
        source_finding(
          "worker-outside-directory",
          Error,
          file,
          position,
          detail,
        ),
      )
    } else if !self.project.exists(path) {
      self.add(
        source_finding(
          "unresolved-worker",
          Error,
          file,
          position,
          "Worker entry \{path} does not exist; wx.createWorker takes the file path from the mini program root, including .js.",
        ),
      )
    }
  }
}
