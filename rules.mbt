// ---------------------------------------------------------------------------
// WXML template scope

///|
/// Templates visible in a WXML file: its own, those defined directly in the
/// files it imports (WXML import is not transitive), and those visible to
/// every file that includes it, since include pastes markup into the
/// includer.
fn Analyzer::visible_templates(
  self : Analyzer,
  file : String,
  visiting : Map[String, Unit],
) -> Map[String, Unit] {
  let visible : Map[String, Unit] = Map([])
  guard self.wxml.get(file) is Some(info) && !visiting.contains(file) else {
    return visible
  }
  visiting[file] = ()
  for name, _ in info.templates {
    visible[name] = ()
  }
  for imported in info.imports {
    if self.wxml.get(imported) is Some(target) {
      for name, _ in target.templates {
        visible[name] = ()
      }
    }
  }
  for includer, includer_info in self.wxml {
    if includer_info.includes.contains(file) {
      for name, _ in self.visible_templates(includer, visiting) {
        visible[name] = ()
      }
    }
  }
  visiting.remove(file)
  visible
}

///|
fn Analyzer::check_templates(self : Analyzer) -> Unit {
  for file, info in self.wxml {
    if info.template_uses.is_empty() {
      continue
    }
    let visible = self.visible_templates(file, Map([]))
    for use_ in info.template_uses {
      let (name, position) = use_
      if !visible.contains(name) {
        self.add(
          source_finding(
            "unknown-template",
            Error,
            file,
            position,
            "Template '\{name}' is not defined in this file or in a file it imports.",
          ),
        )
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Unused components

///|
/// Tags used by a page or component: those in its WXML and in every WXML
/// file reachable from it through import and include.
fn Analyzer::used_tags(self : Analyzer, base : String) -> Map[String, Unit] {
  let tags : Map[String, Unit] = Map([])
  let pending = [base + ".wxml"]
  let seen : Map[String, Unit] = Map([])
  while pending.pop() is Some(file) {
    if seen.contains(file) {
      continue
    }
    seen[file] = ()
    guard self.wxml.get(file) is Some(info) else { continue }
    for tag, _ in info.tags {
      tags[tag] = ()
    }
    for next in info.imports {
      pending.push(next)
    }
    for next in info.includes {
      pending.push(next)
    }
  }
  tags
}

///|
fn Analyzer::check_unused_components(self : Analyzer) -> Unit {
  for base, unit_info in self.units {
    // Components declared in app.json are global and may be used anywhere.
    if unit_info.kind is App || unit_info.declared.is_empty() {
      continue
    }
    let used = self.used_tags(base)
    for declared in unit_info.declared {
      if !used.contains(declared.tag) {
        self.add(
          config_finding(
            "unused-component",
            Warning,
            base + ".json",
            declared.location,
            "<\{declared.tag}> is declared but never used in \{base}.wxml or the WXML it imports; it is still packaged and initialized.",
          ),
        )
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Package boundaries

///|
fn Analyzer::package_label(self : Analyzer, index : Int32) -> String {
  if index == 0 {
    "the main package"
  } else {
    "subpackage \{self.packages[index].name}"
  }
}

///|
fn Analyzer::edge_finding(
  self : Analyzer,
  edge : Edge,
  code : String,
  detail : String,
) -> Unit {
  self.add({
    code,
    severity: Error,
    file: edge.file,
    location: edge.location,
    line: edge.line,
    column: edge.column,
    detail,
  })
}

///|
/// Enforces the WeChat packaging rules: the main package cannot reach into
/// a subpackage, subpackages cannot reach into each other, and independent
/// subpackages cannot depend on the main package either. `require.async`
/// and components with a placeholder are the sanctioned exceptions.
fn Analyzer::check_boundaries(self : Analyzer) -> Unit {
  for edge in self.edges {
    // Worker code has its own rule, check_workers.
    if edge.kind is PageFile || self.in_workers(edge.from) {
      continue
    }
    let from = self.owner(edge.from)
    let to = self.owner(edge.to)
    if from == to {
      continue
    }
    let target = "\{edge.to} (\{self.package_label(to)})"
    if self.packages[from].independent {
      self.edge_finding(
        edge,
        "independent-subpackage-dependency",
        "Independent \{self.package_label(from)} must not depend on \{target}; it runs without the main package loaded.",
      )
      continue
    }
    if to == 0 || edge.kind.is_async() {
      continue
    }
    if from == 0 {
      self.edge_finding(
        edge,
        "main-package-references-subpackage",
        "The main package cannot use \{target} through a \{edge.kind.label()}; move the file to the main package or load it with require.async / componentPlaceholder.",
      )
    } else {
      self.edge_finding(
        edge,
        "cross-subpackage-reference",
        "\{self.package_label(from)} cannot use \{target} through a \{edge.kind.label()}; subpackages can only share code through the main package.",
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Navigation

///|
fn Analyzer::check_navigation(self : Analyzer) -> Unit {
  for site in self.navigations {
    // An empty url, a fragment, `javascript:` or a web address does not
    // name a page: WeUI-style markup uses them as inert link targets.
    if site.url == "" ||
      site.url.has_prefix("#") ||
      site.url.has_prefix("javascript:") ||
      is_external(site.url) {
      continue
    }
    let route = if site.url.has_prefix("/") {
      normalize_path(site.url)
    } else {
      // A relative url is resolved against the current page route. Outside
      // a page file the current page is unknown, so the call is skipped.
      match site.page {
        Some(page) => normalize_path(join_path(dirname(page), site.url))
        None => continue
      }
    }
    let api = site.api.name()
    guard route is Some(route) && route != "" else {
      self.add(
        source_finding(
          "invalid-navigation-target",
          Error,
          site.file,
          site.position,
          "\{api} url '\{site.url}' does not name a page inside the mini program.",
        ),
      )
      continue
    }
    if !self.routes.contains(route) {
      self.add(
        source_finding(
          "unknown-navigation-target",
          Error,
          site.file,
          site.position,
          "\{api} opens '\{route}', which is not registered in app.json.",
        ),
      )
      continue
    }
    let is_tab = self.tab_pages.contains(route)
    match site.api {
      SwitchTab if !is_tab =>
        self.add(
          source_finding(
            "switch-tab-to-non-tab-page",
            Error,
            site.file,
            site.position,
            "wx.switchTab can only open tabBar pages; \{route} is not in tabBar.list.",
          ),
        )
      NavigateTo | RedirectTo if is_tab =>
        self.add(
          source_finding(
            "navigate-to-tab-page",
            Error,
            site.file,
            site.position,
            "\{api} cannot open tabBar page \{route}; use wx.switchTab.",
          ),
        )
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Require cycles

///|
/// Strongly connected components of the synchronous module graph, found
/// with an iterative version of Tarjan's algorithm so that deep require
/// chains cannot overflow the stack. Components are returned in the order
/// their roots finish.
fn strongly_connected(
  nodes : Array[String],
  successors : Map[String, Array[String]],
) -> Array[Array[String]] {
  let index_of : Map[String, Int32] = Map([])
  let low : Map[String, Int32] = Map([])
  let on_stack : Map[String, Unit] = Map([])
  let stack : Array[String] = []
  let result : Array[Array[String]] = []
  let mut counter = 0
  for start in nodes {
    if index_of.contains(start) {
      continue
    }
    // Each frame is a node and the position of its next successor.
    let frames : Array[(String, Int32)] = [(start, 0)]
    index_of[start] = counter
    low[start] = counter
    counter += 1
    stack.push(start)
    on_stack[start] = ()
    while frames.last() is Some((node, next)) {
      let targets = successors.get(node).unwrap_or([])
      if next < targets.length() {
        frames[frames.length() - 1] = (node, next + 1)
        let target = targets[next]
        if !index_of.contains(target) {
          index_of[target] = counter
          low[target] = counter
          counter += 1
          stack.push(target)
          on_stack[target] = ()
          frames.push((target, 0))
        } else if on_stack.contains(target) {
          low[node] = min_int(low[node], index_of[target])
        }
        continue
      }
      ignore(frames.pop())
      if frames.last() is Some((parent, _)) {
        low[parent] = min_int(low[parent], low[node])
      }
      if low[node] == index_of[node] {
        let members = []
        while stack.pop() is Some(item) {
          on_stack.remove(item)
          members.push(item)
          if item == node {
            break
          }
        }
        result.push(members)
      }
    }
  }
  result
}

///|
fn Analyzer::check_require_cycles(self : Analyzer) -> Unit {
  let successors : Map[String, Array[String]] = Map([])
  let nodes : Array[String] = []
  let first_edge : Map[String, Edge] = Map([])
  for edge in self.edges {
    guard edge.kind is (Require | EsImport) else { continue }
    for node in [edge.from, edge.to] {
      if !successors.contains(node) {
        successors[node] = []
        nodes.push(node)
      }
    }
    successors[edge.from].push(edge.to)
    if !first_edge.contains(edge.from) {
      first_edge[edge.from] = edge
    }
  }
  for members in strongly_connected(nodes, successors) {
    let self_loop = members.length() == 1 &&
      successors[members[0]].contains(members[0])
    guard members.length() > 1 || self_loop else { continue }
    members.sort()
    let anchor = first_edge[members[0]]
    let names = members.map(fn(m) { self.project.source_name(m) })
    self.add({
      code: "require-cycle",
      severity: Warning,
      file: anchor.file,
      location: "",
      line: anchor.line,
      column: anchor.column,
      detail: "Modules require each other: \{names.join(" -> ")}. One side sees a partially initialized module.exports.",
    })
  }
}

// ---------------------------------------------------------------------------
// Reachability, package sizes and move suggestions

///|
/// Files the developer tools treat as project configuration rather than
/// packaged code.
fn is_project_file(path : String) -> Bool {
  [
    "project.config.json", "project.private.config.json", "package.json", "package-lock.json",
    "yarn.lock", "pnpm-lock.yaml", "tsconfig.json", "jsconfig.json",
  ].contains(path) ||
  path.split("/").any(fn(segment) { segment.has_prefix(".") }) ||
  [".md", ".ts", ".map", ".log", ""].contains(extension(path))
}

///|
let packaged_extensions : Array[String] = [
  ".js", ".wxml", ".wxss", ".wxs", ".json", ".png", ".jpg", ".jpeg", ".gif", ".svg",
  ".webp",
]

///|
/// Files reached from `starts` over every dependency edge except the
/// asynchronous ones, which load on demand from their own package.
fn Analyzer::reach(
  self : Analyzer,
  starts : Array[String],
) -> Map[String, Unit] {
  let successors : Map[String, Array[String]] = Map([])
  for edge in self.edges {
    if edge.kind.is_async() {
      continue
    }
    match successors.get(edge.from) {
      Some(list) => list.push(edge.to)
      None => successors[edge.from] = [edge.to]
    }
  }
  let seen : Map[String, Unit] = Map([])
  let pending = starts.copy()
  while pending.pop() is Some(node) {
    if seen.contains(node) {
      continue
    }
    seen[node] = ()
    for next in successors.get(node).unwrap_or([]) {
      pending.push(next)
    }
  }
  seen
}

///|
/// Size of one package as shipped.
#derive(Eq, Debug)
pub(all) struct PackageStats {
  name : String
  root : String
  independent : Bool
  files : Int32
  bytes : Int32
  /// Bytes of main-package files used only by this subpackage.
  movable_bytes : Int32
}

///|
fn Analyzer::check_sizes(
  self : Analyzer,
  options : Options,
) -> Array[PackageStats] {
  let all_entries = ["app"]
  for pkg in self.packages {
    for page in pkg.pages {
      all_entries.push(page)
    }
  }

  for edge in self.edges {
    if edge.kind.is_async() {
      all_entries.push(edge.to)
    }
  }
  let reachable = self.reach(all_entries)
  for path, size in self.project.sizes {
    if reachable.contains(path) ||
      is_project_file(path) ||
      path.has_prefix("miniprogram_npm/") ||
      path.contains("/miniprogram_npm/") ||
      self.in_workers(path) ||
      !packaged_extensions.contains(extension(path)) {
      continue
    }
    self.add(
      config_finding(
        "unreferenced-file",
        Info,
        path,
        "",
        "Nothing references this file (\{size} bytes); it is still packaged into \{self.package_label(self.owner(path))}.",
      ),
    )
  }

  // Which packages reach each main-package file synchronously.
  let main_starts = ["app"]
  for page in self.packages[0].pages {
    main_starts.push(page)
  }
  let main_reach = self.reach(main_starts)
  let users : Map[String, Array[Int32]] = Map([])
  for index, pkg in self.packages {
    if index == 0 {
      continue
    }
    for file, _ in self.reach(pkg.pages) {
      if self.project.exists(file) &&
        self.owner(file) == 0 &&
        !main_reach.contains(file) {
        match users.get(file) {
          Some(list) => list.push(index)
          None => users[file] = [index]
        }
      }
    }
  }
  let movable : Array[Int32] = Array::make(self.packages.length(), 0)
  for file, list in users {
    guard list is [only] else { continue }
    let size = self.project.size(file)
    movable[only] += size
    self.add(
      config_finding(
        "move-to-subpackage",
        Info,
        file,
        "",
        "Only \{self.package_label(only)} uses this file; moving it under \{self.packages[only].root}/ would take \{size} bytes out of the main package.",
      ),
    )
  }

  let stats = self.packages.mapi(fn(index, pkg) {
    {
      name: pkg.name,
      root: pkg.root,
      independent: pkg.independent,
      files: 0,
      bytes: 0,
      movable_bytes: movable[index],
    }
  })
  let mut total = 0
  for path, size in self.project.sizes {
    if is_project_file(path) {
      continue
    }
    let index = self.owner(path)
    stats[index] = {
      ..stats[index],
      files: stats[index].files + 1,
      bytes: stats[index].bytes + size,
    }
    total += size
  }
  for index, stat in stats {
    if stat.bytes > options.max_package_bytes {
      self.add(
        config_finding(
          "package-size-exceeded",
          Error,
          "app.json",
          if index == 0 {
            "$.pages"
          } else {
            "$.subpackages"
          },
          "\{self.package_label(index)} is \{stat.bytes} bytes, over the \{options.max_package_bytes} byte limit.",
        ),
      )
    }
  }
  if total > options.max_total_bytes {
    self.add(
      config_finding(
        "total-size-exceeded",
        Error,
        "app.json",
        "$",
        "All packages together are \{total} bytes, over the \{options.max_total_bytes} byte limit.",
      ),
    )
  }
  stats
}
