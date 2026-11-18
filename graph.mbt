///|
#derive(Eq, Debug)
pub(all) enum EdgeKind {
  /// A page or component owns its `.json`/`.js`/`.wxml`/`.wxss` files.
  PageFile
  Require
  /// `require.async`: loaded on demand, may cross pkg boundaries.
  RequireAsync
  EsImport
  Component
  /// A component with a `componentPlaceholder`, loaded asynchronously.
  AsyncComponent
  WxmlImport
  WxmlInclude
  Wxs
  WxssImport
  Asset
}

///|
pub fn EdgeKind::label(self : EdgeKind) -> String {
  match self {
    PageFile => "file"
    Require => "require"
    RequireAsync => "require.async"
    EsImport => "import"
    Component => "component"
    AsyncComponent => "async component"
    WxmlImport => "wxml import"
    WxmlInclude => "wxml include"
    Wxs => "wxs"
    WxssImport => "wxss import"
    Asset => "asset"
  }
}

///|
/// Whether the target is loaded lazily, which is the documented way to
/// reference code in another subpackage.
fn EdgeKind::is_async(self : EdgeKind) -> Bool {
  self is (RequireAsync | AsyncComponent)
}

///|
/// A dependency between two graph nodes. Nodes are file paths, plus the
/// base paths (without extension) of the app, pages and components.
/// `file`/`location`/`line`/`column` say where the reference is written.
#derive(Eq, Debug)
pub(all) struct Edge {
  from : String
  to : String
  kind : EdgeKind
  file : String
  location : String
  line : Int32
  column : Int32
}

///|
#derive(Eq, Debug)
pub(all) enum UnitKind {
  App
  Page
  Component
}

///|
/// Data collected while reading one WXML file.
priv struct WxmlInfo {
  templates : Map[String, Unit]
  template_uses : Array[(String, @scan.Position)]
  imports : Array[String]
  includes : Array[String]
  tags : Map[String, Unit]
}

///|
priv struct Declared {
  tag : String
  location : String
}

///|
priv struct UnitInfo {
  kind : UnitKind
  declared : Array[Declared]
}

///|
priv struct NavigationSite {
  api : @jsscan.NavigationApi
  url : String
  file : String
  position : @scan.Position
  /// The route of the page this file belongs to, when it is a page file.
  page : String?
}

///|
priv struct PackageInfo {
  name : String
  root : String
  independent : Bool
  pages : Array[String]
}

///|
priv enum Work {
  VisitUnit(String, UnitKind)
  VisitFile(String)
}

///|
priv struct Analyzer {
  project : Project
  findings : Array[Finding]
  packages : Array[PackageInfo]
  routes : Map[String, Unit]
  tab_pages : Map[String, Unit]
  edges : Array[Edge]
  units : Map[String, UnitInfo]
  files_seen : Map[String, Unit]
  wxml : Map[String, WxmlInfo]
  navigations : Array[NavigationSite]
  queue : Array[Work]
  /// Component path prefixes served by `useExtendedLib`, which DevTools
  /// supplies at build time instead of reading from the project.
  extended_prefixes : Array[String]
}

///|
fn Analyzer::add(self : Analyzer, finding : Finding) -> Unit {
  self.findings.push(finding)
}

///|
fn Analyzer::enqueue_unit(
  self : Analyzer,
  base : String,
  kind : UnitKind,
) -> Unit {
  if !self.units.contains(base) {
    self.units[base] = { kind, declared: [], }
    self.queue.push(VisitUnit(base, kind))
  }
}

///|
fn Analyzer::enqueue_file(self : Analyzer, path : String) -> Unit {
  if !self.files_seen.contains(path) {
    self.files_seen[path] = ()
    self.queue.push(VisitFile(path))
  }
}

///|
fn Analyzer::edge(
  self : Analyzer,
  from : String,
  to : String,
  kind : EdgeKind,
  file : String,
  location~ : String = "",
  position? : @scan.Position,
) -> Unit {
  let (line, column) = match position {
    Some(p) => (p.line, p.column)
    None => (0, 0)
  }
  self.edges.push({ from, to, kind, file, location, line, column, })
}

///|
/// Reads a text file, reporting files that are not valid UTF-8.
fn Analyzer::read(self : Analyzer, path : String) -> String? {
  match (self.project.reader)(path) {
    Some(text) => Some(text)
    None => {
      self.add(
        config_finding(
          "unreadable-file",
          Error,
          path,
          "",
          "The file could not be read as UTF-8 text.",
        ),
      )
      None
    }
  }
}

///|
fn Analyzer::route_of_file(self : Analyzer, path : String) -> String? {
  let base = strip_extension(path)
  if self.routes.contains(base) {
    Some(base)
  } else {
    None
  }
}

///|
/// Index into `packages` of the pkg that ships `path`; 0 is the main
/// pkg. Subpackage roots never overlap once the manifest checks pass,
/// and the longest matching root wins if they do.
fn Analyzer::owner(self : Analyzer, path : String) -> Int32 {
  let mut best = 0
  for index, pkg in self.packages {
    if index > 0 &&
      is_under(path, pkg.root) &&
      pkg.root.length() > self.packages[best].root.length() {
      best = index
    }
  }
  best
}

// ---------------------------------------------------------------------------
// Manifest model

///|
fn string_list(value : Json?) -> Array[String] {
  guard value is Some(Array(items)) else { return [] }
  let out = []
  for item in items {
    if item is String(text) {
      out.push(text)
    }
  }
  out
}

///|
/// Reads the pkg layout from `app.json`. Structural problems have
/// already been reported by `audit_manifest`, so invalid entries are
/// silently skipped here.
fn Analyzer::load_manifest(
  self : Analyzer,
  manifest : Map[String, Json],
) -> Unit {
  let main_pages = string_list(manifest.get("pages")).filter(fn(p) {
    is_safe_path(p, route_stem=true)
  })
  self.packages.push({
    name: "__APP__",
    root: "",
    independent: false,
    pages: main_pages,
  })
  let subpackages = match manifest.get("subpackages") {
    Some(value) => Some(value)
    None => manifest.get("subPackages")
  }
  if subpackages is Some(Array(entries)) {
    for entry in entries {
      guard entry is Object(fields) &&
        fields.get("root") is Some(String(raw_root)) &&
        is_safe_path(raw_root) else {
        continue
      }
      let root = match raw_root.strip_suffix("/") {
        Some(trimmed) => trimmed.to_owned()
        None => raw_root
      }
      let name = match fields.get("name") {
        Some(String(name)) if name.trim() != "" => name
        _ => root
      }
      let pages = string_list(fields.get("pages"))
        .filter(fn(p) { is_safe_path(p, route_stem=true) })
        .map(fn(p) { root + "/" + p })
      self.packages.push({
        name,
        root,
        independent: fields.get("independent") is Some(True),
        pages,
      })
    }
  }
  for pkg in self.packages {
    for page in pkg.pages {
      self.routes[page] = ()
    }
  }
  if manifest.get("useExtendedLib") is Some(Object(libraries)) {
    match libraries.get("weui") {
      Some(True) | Some(String(_)) =>
        self.extended_prefixes.push("weui-miniprogram/")
      _ => ()
    }
  }
  if manifest.get("tabBar") is Some(Object(tab_bar)) &&
    tab_bar.get("list") is Some(Array(tabs)) {
    for tab in tabs {
      if tab is Object(item) && item.get("pagePath") is Some(String(path)) {
        self.tab_pages[path] = ()
      }
    }
  }
}

///|
/// Adds the entry points: the app itself, every registered page, global
/// components, a custom tab bar, and files named by `app.json`.
fn Analyzer::seed(self : Analyzer, manifest : Map[String, Json]) -> Unit {
  self.enqueue_unit("app", App)
  for pkg in self.packages {
    for page in pkg.pages {
      self.enqueue_unit(page, Page)
    }
  }
  if manifest.get("tabBar") is Some(Object(tab_bar)) &&
    tab_bar.get("custom") is Some(True) {
    match resolve_component(self.project, "", "custom-tab-bar/index") {
      Found(base) => {
        self.edge(
          "app",
          base,
          Component,
          "app.json",
          location="$.tabBar.custom",
        )
        self.enqueue_unit(base, Component)
      }
      _ =>
        self.add(
          config_finding(
            "missing-custom-tab-bar",
            Error,
            "app.json",
            "$.tabBar.custom",
            "A custom tab bar needs a component at custom-tab-bar/index.",
          ),
        )
    }
  }
  for field in ["sitemapLocation", "themeLocation"] {
    if manifest.get(field) is Some(String(reference)) {
      let reference = if field == "themeLocation" && extension(reference) == "" {
        reference + ".json"
      } else {
        reference
      }
      match resolve_reference(self.project, "", reference, asset_lookup) {
        Found(path) => {
          self.edge("app", path, Asset, "app.json", location="$.\{field}")
          self.enqueue_file(path)
        }
        External => ()
        _ =>
          self.add(
            config_finding(
              "missing-config-file",
              Error,
              "app.json",
              "$.\{field}",
              "\{reference} does not exist.",
            ),
          )
      }
    }
  }
  if manifest.get("tabBar") is Some(Object(tab_bar)) &&
    tab_bar.get("list") is Some(Array(tabs)) {
    for tab in tabs {
      guard tab is Object(item) else { continue }
      for field in ["iconPath", "selectedIconPath"] {
        if item.get(field) is Some(String(reference)) &&
          normalize_path(reference) is Some(path) &&
          self.project.exists(path) {
          self.edge("app", path, Asset, "app.json", location="$.tabBar.list")
          self.enqueue_file(path)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Pages and components

///|
fn Analyzer::visit_unit(
  self : Analyzer,
  base : String,
  kind : UnitKind,
) -> Unit {
  let extensions = match kind {
    App => [".json", ".js", ".wxss"]
    _ => [".json", ".js", ".wxml", ".wxss"]
  }
  for ext in extensions {
    if self.project.exists(base + ext) {
      self.edge(base, base + ext, PageFile, base + ext)
      self.files_seen[base + ext] = ()
      if ext != ".json" {
        self.queue.push(VisitFile(base + ext))
      }
    }
  }
  if kind is Component {
    let missing = [".js", ".wxml"].filter(fn(ext) {
      !self.project.exists(base + ext)
    })
    if !missing.is_empty() {
      self.add(
        config_finding(
          "incomplete-component",
          Error,
          base + ".json",
          "",
          "Component \{base} has no \{missing.map(fn(e) { base + e }).join(" or ")}.",
        ),
      )
    }
  }
  let json_file = base + ".json"
  guard self.project.exists(json_file) && self.read(json_file) is Some(text) else {
    return
  }
  let data = @json.parse(text) catch {
    error => {
      self.add(
        config_finding("invalid-json", Error, json_file, "$", "\{error}"),
      )
      return
    }
  }
  guard data is Object(config) else {
    self.add(
      config_finding(
        "invalid-json",
        Error,
        json_file,
        "$",
        "Expected a JSON object.",
      ),
    )
    return
  }
  if kind is Component && !(config.get("component") is Some(True)) {
    self.add(
      config_finding(
        "missing-component-flag",
        Error,
        json_file,
        "$.component",
        "\{base} is used as a component but its JSON lacks \"component\": true.",
      ),
    )
  }
  self.read_components(base, kind, json_file, config)
}

///|
fn Analyzer::read_components(
  self : Analyzer,
  base : String,
  kind : UnitKind,
  json_file : String,
  config : Map[String, Json],
) -> Unit {
  let placeholders : Map[String, Unit] = Map([])
  if config.get("componentPlaceholder") is Some(Object(entries)) {
    for tag, _ in entries {
      placeholders[tag] = ()
    }
  }
  let references : Array[(String, String, String)] = []
  match config.get("usingComponents") {
    None => ()
    Some(Object(entries)) =>
      for tag, value in entries {
        let location = key_path("$.usingComponents", tag)
        match value {
          String(reference) => references.push((tag, reference, location))
          _ =>
            self.add(
              config_finding(
                "invalid-component-path",
                Error,
                json_file,
                location,
                "Expected a component path string.",
              ),
            )
        }
      }
    Some(_) =>
      self.add(
        config_finding(
          "invalid-component-path",
          Error,
          json_file,
          "$.usingComponents",
          "Expected an object mapping tag names to component paths.",
        ),
      )
  }
  if config.get("componentGenerics") is Some(Object(generics)) {
    for name, generic in generics {
      if generic is Object(fields) &&
        fields.get("default") is Some(String(reference)) {
        references.push(
          (name, reference, key_path("$.componentGenerics", name) + ".default"),
        )
      }
    }
  }
  let directory = dirname(base)
  let info = self.units.get(base).unwrap()
  for item in references {
    let (tag, reference, location) = item
    if !location.has_prefix("$.componentGenerics") {
      info.declared.push({ tag, location, })
    }
    let resolution = if self.extended_prefixes
      .iter()
      .any(fn(prefix) { reference.has_prefix(prefix) }) {
      External
    } else {
      resolve_component(self.project, directory, reference)
    }
    match resolution {
      Found(target) => {
        let edge_kind : EdgeKind = if placeholders.contains(tag) {
          AsyncComponent
        } else {
          Component
        }
        self.edge(base, target, edge_kind, json_file, location~)
        self.enqueue_unit(target, Component)
      }
      External => ()
      Missing(path) =>
        self.add(
          config_finding(
            "unresolved-component",
            Error,
            json_file,
            location,
            "No component \{path}.json (or \{path}/index.json) for <\{tag}>.",
          ),
        )
      Escapes =>
        self.add(
          config_finding(
            "unresolved-component",
            Error,
            json_file,
            location,
            "\{reference} points outside the mini program directory.",
          ),
        )
    }
    ignore(kind)
  }
}

// ---------------------------------------------------------------------------
// Source files

///|
fn Analyzer::reference(
  self : Analyzer,
  file : String,
  position : @scan.Position,
  reference : String,
  lookup : Lookup,
  kind : EdgeKind,
  missing_code : String,
) -> String? {
  match resolve_reference(self.project, dirname(file), reference, lookup) {
    Found(target) => {
      self.edge(file, target, kind, file, position~)
      self.enqueue_file(target)
      Some(target)
    }
    External => None
    Missing(path) => {
      self.add(
        source_finding(
          missing_code,
          Error,
          file,
          position,
          "'\{reference}' does not resolve to an existing file (looked for \{path}).",
        ),
      )
      None
    }
    Escapes => {
      self.add(
        source_finding(
          missing_code,
          Error,
          file,
          position,
          "'\{reference}' points outside the mini program directory.",
        ),
      )
      None
    }
  }
}

///|
fn Analyzer::visit_script(self : Analyzer, path : String, wxs : Bool) -> Unit {
  guard self.read(path) is Some(text) else { return }
  let facts = @jsscan.analyze(
    text,
    typescript=self.project.source_name(path).has_suffix(".ts"),
  )
  for error in facts.errors {
    self.add(
      source_finding(
        "script-syntax-error",
        Warning,
        path,
        error.position,
        error.message,
      ),
    )
  }
  for dependency in facts.dependencies {
    if wxs {
      // WXS modules may only require other .wxs files, by relative path.
      let ext = extension(dependency.specifier)
      if ext != "" && ext != ".wxs" {
        self.add(
          source_finding(
            "wxs-requires-non-wxs",
            Error,
            path,
            dependency.position,
            "WXS can only require .wxs modules, not '\{dependency.specifier}'.",
          ),
        )
      } else {
        ignore(
          self.reference(
            path,
            dependency.position,
            dependency.specifier,
            wxs_lookup,
            Wxs,
            "unresolved-module",
          ),
        )
      }
      continue
    }
    let kind : EdgeKind = match dependency.kind {
      RequireAsync => RequireAsync
      Require => Require
      Import | DynamicImport => EsImport
    }
    ignore(
      self.reference(
        path,
        dependency.position,
        dependency.specifier,
        script_lookup,
        kind,
        "unresolved-module",
      ),
    )
  }
  if !wxs {
    let page = self.route_of_file(path)
    for navigation in facts.navigations {
      self.navigations.push({
        api: navigation.api,
        url: navigation.url,
        file: path,
        position: navigation.position,
        page,
      })
    }
  }
}

///|
let media_tags : Array[String] = ["image", "cover-image", "video", "audio"]

///|
fn Analyzer::visit_wxml(self : Analyzer, path : String) -> Unit {
  guard self.read(path) is Some(text) else { return }
  let document = @wxml.parse(text)
  for error in document.errors {
    self.add(
      source_finding(
        "wxml-syntax-error",
        Error,
        path,
        error.position,
        error.message,
      ),
    )
  }
  let info : WxmlInfo = {
    templates: Map([]),
    template_uses: [],
    imports: [],
    includes: [],
    tags: Map([]),
  }
  self.wxml[path] = info
  let page = self.route_of_file(path)
  document.each_element(fn(element) {
    info.tags[element.name] = ()
    for attribute in element.attributes {
      if attribute.name.has_prefix("generic:") && attribute.value is Some(value) {
        info.tags[value] = ()
      }
    }
    match element.name {
      "import" | "include" =>
        if element.static_value("src") is Some(src) {
          let kind : EdgeKind = if element.name == "import" {
            WxmlImport
          } else {
            WxmlInclude
          }
          if self.reference(
              path,
              element.position,
              src,
              wxml_lookup,
              kind,
              "unresolved-wxml-reference",
            )
            is Some(target) {
            if kind is WxmlImport {
              info.imports.push(target)
            } else {
              info.includes.push(target)
            }
          }
        }
      "wxs" => {
        if element.static_value("module") is None {
          self.add(
            source_finding(
              "wxs-missing-module",
              Error,
              path,
              element.position,
              "<wxs> needs a module attribute.",
            ),
          )
        }
        if element.static_value("src") is Some(src) {
          ignore(
            self.reference(
              path,
              element.position,
              src,
              wxs_lookup,
              Wxs,
              "unresolved-wxml-reference",
            ),
          )
        }
      }
      "template" => {
        if element.static_value("name") is Some(name) {
          info.templates[name] = ()
        }
        if element.static_value("is") is Some(name) {
          info.template_uses.push((name, element.position))
        }
      }
      "navigator" =>
        if element.static_value("target") != Some("miniProgram") &&
          element.static_value("url") is Some(url) {
          // DevTools accepts the camelCase spelling `openType` too.
          let open_type = match element.static_value("open-type") {
            Some(value) => value
            None => element.static_value("openType").unwrap_or("navigate")
          }
          let api : @jsscan.NavigationApi? = match open_type {
            "navigate" => Some(NavigateTo)
            "redirect" => Some(RedirectTo)
            "switchTab" => Some(SwitchTab)
            "reLaunch" => Some(ReLaunch)
            _ => None
          }
          if api is Some(api) {
            let url = match url.find("?") {
              Some(index) => url[:index].to_owned()
              None => url
            }
            self.navigations.push({
              api,
              url,
              file: path,
              position: element.position,
              page,
            })
          }
        }
      name if media_tags.contains(name) =>
        if element.static_value("src") is Some(src) && src != "" {
          ignore(
            self.reference(
              path,
              element.position,
              src,
              asset_lookup,
              Asset,
              "missing-asset",
            ),
          )
        }
      _ => ()
    }
  })
}

///|
fn Analyzer::visit_wxss(self : Analyzer, path : String) -> Unit {
  guard self.read(path) is Some(text) else { return }
  // Less and Sass sources allow `//` comments; plain WXSS does not.
  let facts = @wxss.analyze(
    text,
    line_comments=self.project.source_name(path) != path,
  )
  for error in facts.errors {
    self.add(
      source_finding(
        "wxss-syntax-error",
        Warning,
        path,
        error.position,
        error.message,
      ),
    )
  }
  for reference in facts.references {
    match reference.kind {
      Import =>
        ignore(
          self.reference(
            path,
            reference.position,
            reference.target,
            wxss_lookup,
            WxssImport,
            "unresolved-style-import",
          ),
        )
      Url =>
        if !is_external(reference.target) && reference.target != "" {
          self.add(
            source_finding(
              "local-wxss-resource",
              Warning,
              path,
              reference.position,
              "WXSS cannot load local file \{reference.target} on devices; use a network URL, base64 data or an <image> element.",
            ),
          )
        }
    }
  }
}

///|
fn Analyzer::visit_file(self : Analyzer, path : String) -> Unit {
  match extension(path) {
    ".js" => self.visit_script(path, false)
    ".wxs" => self.visit_script(path, true)
    ".wxml" => self.visit_wxml(path)
    ".wxss" => self.visit_wxss(path)
    _ => ()
  }
}

///|
fn Analyzer::run(self : Analyzer) -> Unit {
  // Breadth-first keeps findings ordered from entry points outwards. The
  // queue only grows, so a moving head index avoids quadratic shifting.
  let mut head = 0
  while head < self.queue.length() {
    let work = self.queue[head]
    head += 1
    match work {
      VisitUnit(base, kind) => self.visit_unit(base, kind)
      VisitFile(path) => self.visit_file(path)
    }
  }
}
