///|
priv struct Route {
  path : String
  location : String
  main_package : Bool
}

///|
fn finding(
  issues : Array[Json],
  code : String,
  location : String,
  detail : String,
) -> Unit {
  issues.push({ "code": code, "location": location, "detail": detail })
}

///|
fn is_windows_device_name(segment : String) -> Bool {
  let stem = match segment.split_once(".") {
    Some((base, _)) => base.trim().to_owned().to_lower()
    None => segment.to_lower()
  }
  match stem {
    "con" | "prn" | "aux" | "nul" => true
    _ if stem.has_prefix("com") || stem.has_prefix("lpt") =>
      match stem[3:].to_owned() {
        "1"
        | "2"
        | "3"
        | "4"
        | "5"
        | "6"
        | "7"
        | "8"
        | "9"
        | "¹"
        | "²"
        | "³" => true
        _ => false
      }
    _ => false
  }
}

///|
fn is_safe_path(path : String, route_stem~ : Bool = false) -> Bool {
  for character in path.iter() {
    if character < ' ' ||
      character == '\u007f' ||
      character == '\\' ||
      character == ':' ||
      character == '?' ||
      character == '#' ||
      character == '<' ||
      character == '>' ||
      character == '"' ||
      character == '|' ||
      character == '*' {
      return false
    }
  }
  let parts = path.split("/").to_array()
  for index, part in parts {
    let segment = part.to_owned()
    // A page basename is followed by .js or .wxml on disk.
    let full_component = !route_stem || index + 1 < parts.length()
    if segment == "" ||
      segment == "." ||
      segment == ".." ||
      segment.trim().to_owned() != segment ||
      (full_component && segment.has_suffix(".")) ||
      is_windows_device_name(segment) {
      return false
    }
  }
  true
}

///|
fn read_pages(
  field : Json?,
  location : String,
  root : String?,
  routes : Array[Route],
  issues : Array[Json],
) -> Unit {
  guard field is Some(Array(pages)) && !pages.is_empty() else {
    finding(
      issues, "invalid-pages", location, "Expected a non-empty array of page paths.",
    )
    return
  }
  for index, page in pages {
    let item_location = "\{location}[\{index}]"
    guard page is String(path) &&
      is_safe_path(path, route_stem=true) &&
      !path.has_suffix(".js") &&
      !path.has_suffix(".wxml") &&
      !path.has_suffix(".json") &&
      !path.has_suffix(".wxss") else {
      finding(
        issues, "invalid-route", item_location, "Expected a portable relative page path without a file extension.",
      )
      continue
    }
    let full_path = match root {
      Some(package_root) => "\{package_root}/\{path}"
      None => path
    }
    routes.push({
      path: full_path,
      location: item_location,
      main_package: root is None,
    })
  }
}

///|
fn read_subpackages(
  manifest : Map[String, Json],
  routes : Array[Route],
  issues : Array[Json],
) -> Array[String] {
  let package_field = match
    (manifest.get("subpackages"), manifest.get("subPackages")) {
    (Some(lower), Some(_)) => {
      finding(
        issues, "duplicate-subpackage-field", "$.subPackages", "Use only one spelling of subpackages.",
      )
      Some(("subpackages", lower))
    }
    (Some(lower), None) => Some(("subpackages", lower))
    (None, Some(upper)) => Some(("subPackages", upper))
    (None, None) => None
  }
  guard package_field is Some((key, value)) else { return [] }
  guard value is Array(packages) else {
    finding(
      issues,
      "invalid-subpackages",
      "$.\{key}",
      "Expected an array of subpackages.",
    )
    return []
  }
  let roots : Array[String] = []
  for index, entry in packages {
    let location = "$.\{key}[\{index}]"
    guard entry is Object(fields) else {
      finding(
        issues, "invalid-subpackage", location, "Expected a subpackage object.",
      )
      continue
    }
    guard fields.get("root") is Some(String(root)) && is_safe_path(root) else {
      finding(
        issues,
        "invalid-subpackage-root",
        "\{location}.root",
        "Expected a portable relative directory path.",
      )
      continue
    }
    for other in roots {
      if root == other ||
        root.has_prefix(other + "/") ||
        other.has_prefix(root + "/") {
        finding(
          issues,
          "overlapping-subpackage-root",
          "\{location}.root",
          "\{root} conflicts with \{other}.",
        )
      }
    }
    roots.push(root)
    read_pages(
      fields.get("pages"),
      "\{location}.pages",
      Some(root),
      routes,
      issues,
    )
  }
  roots
}

///|
fn enclosing_subpackage(path : String, roots : Array[String]) -> String? {
  for root in roots {
    if path.has_prefix(root + "/") {
      return Some(root)
    }
  }
  None
}

///|
fn check_references(
  manifest : Map[String, Json],
  routes : Map[String, Route],
  issues : Array[Json],
) -> Unit {
  match manifest.get("entryPagePath") {
    None => ()
    Some(String(path)) if routes.contains(path) => ()
    Some(_) =>
      finding(
        issues, "unknown-entry-route", "$.entryPagePath", "Expected a declared route without query parameters.",
      )
  }
  guard manifest.get("tabBar") is Some(tab_bar) else { return }
  guard tab_bar is Object(fields) && fields.get("list") is Some(Array(tabs)) else {
    finding(
      issues, "invalid-tab-bar", "$.tabBar.list", "Expected an array of tab items.",
    )
    return
  }
  if tabs.length() < 2 || tabs.length() > 5 {
    finding(
      issues, "invalid-tab-count", "$.tabBar.list", "Expected between two and five tab items.",
    )
  }
  for index, tab in tabs {
    let location = "$.tabBar.list[\{index}].pagePath"
    guard tab is Object(item) &&
      item.get("pagePath") is Some(String(path)) &&
      routes.get(path) is Some(route) &&
      route.main_package else {
      finding(
        issues, "tab-route-not-in-main-package", location, "Expected a page listed in the main package.",
      )
      continue
    }
  }
}

///|
pub fn audit_manifest(content : String, files : Array[String]) -> Json {
  let issues : Array[Json] = []
  let data = @json.parse(content, reject_duplicate_keys=true) catch {
    error => {
      finding(issues, "invalid-json", "$", "\{error}")
      return Json::array(issues)
    }
  }
  guard data is Object(manifest) else {
    finding(
      issues, "invalid-manifest", "$", "Expected app.json to contain a JSON object.",
    )
    return Json::array(issues)
  }

  let declared : Array[Route] = []
  read_pages(manifest.get("pages"), "$.pages", None, declared, issues)
  let package_roots = read_subpackages(manifest, declared, issues)

  let paths : Map[String, Unit] = Map([])
  let page_files_by_case : Map[String, Array[String]] = Map([])
  for path in files {
    paths[path] = ()
    let folded_path = path.to_lower()
    if folded_path.has_suffix(".js") || folded_path.has_suffix(".wxml") {
      match page_files_by_case.get(folded_path) {
        Some(matches) => if !matches.contains(path) { matches.push(path) }
        None => page_files_by_case[folded_path] = [path]
      }
    }
  }
  let routes : Map[String, Route] = Map([])
  let case_paths : Map[String, String] = Map([])
  for route in declared {
    if route.main_package &&
      enclosing_subpackage(route.path, package_roots) is Some(root) {
      finding(
        issues,
        "main-route-inside-subpackage",
        route.location,
        "\{route.path} is inside subpackage root \{root}.",
      )
      continue
    }
    if routes.get(route.path) is Some(previous) {
      finding(
        issues,
        "duplicate-route",
        route.location,
        "\{route.path} is also declared at \{previous.location}.",
      )
      continue
    }
    routes[route.path] = route
    let folded_path = route.path.to_lower()
    if case_paths.get(folded_path) is Some(previous) {
      finding(
        issues,
        "route-case-collision",
        route.location,
        "\{route.path} differs from \{previous} only by letter case.",
      )
    } else {
      case_paths[folded_path] = route.path
    }
    for extension in [".js", ".wxml"] {
      let file = route.path + extension
      if paths.contains(file) {
        continue
      }
      match page_files_by_case.get(file.to_lower()) {
        Some(matches) => {
          matches.sort()
          finding(
            issues,
            "page-file-case-mismatch",
            route.location,
            "Expected \{file}, found \{matches.join(", ")}.",
          )
        }
        None => finding(issues, "missing-page-file", route.location, file)
      }
    }
  }
  check_references(manifest, routes, issues)
  check_tab_bar_assets(manifest, paths, issues)
  check_preload_rules(manifest, routes, issues)
  Json::array(issues)
}
