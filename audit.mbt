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
fn is_safe_path(path : String) -> Bool {
  for character in path.iter() {
    if character < ' ' ||
      character == '\u007f' ||
      character == '\\' ||
      character == ':' ||
      character == '?' ||
      character == '#' {
      return false
    }
  }
  for part in path.split("/") {
    let segment = part.to_owned()
    if segment == "" ||
      segment == "." ||
      segment == ".." ||
      segment.trim().to_owned() != segment {
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
      is_safe_path(path) &&
      !path.has_suffix(".js") &&
      !path.has_suffix(".wxml") &&
      !path.has_suffix(".json") &&
      !path.has_suffix(".wxss") else {
      finding(
        issues, "invalid-route", item_location, "Expected a relative page path without a file extension.",
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
) -> Unit {
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
  guard package_field is Some((key, value)) else { return }
  guard value is Array(packages) else {
    finding(
      issues,
      "invalid-subpackages",
      "$.\{key}",
      "Expected an array of subpackages.",
    )
    return
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
        "Expected a relative directory path.",
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
  read_subpackages(manifest, declared, issues)

  let paths : Map[String, Unit] = Map([])
  for path in files {
    paths[path] = ()
  }
  let routes : Map[String, Route] = Map([])
  let case_paths : Map[String, String] = Map([])
  for route in declared {
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
      if !paths.contains(file) {
        finding(issues, "missing-page-file", route.location, file)
      }
    }
  }
  check_references(manifest, routes, issues)
  Json::array(issues)
}
