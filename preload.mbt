///|
fn preload_package_names(manifest : Map[String, Json]) -> Map[String, Unit] {
  let names : Map[String, Unit] = Map([("__APP__", ())])
  let packages = match manifest.get("subpackages") {
    Some(value) => Some(value)
    None => manifest.get("subPackages")
  }
  guard packages is Some(Array(entries)) else { return names }
  for entry in entries {
    guard entry is Object(fields) &&
      fields.get("root") is Some(String(root)) &&
      is_safe_path(root) else {
      continue
    }
    names[root] = ()
    if fields.get("name") is Some(String(name)) && !name.trim().is_empty() {
      names[name] = ()
    }
  }
  names
}

///|
fn check_preload_rule(
  fields : Map[String, Json],
  location : String,
  package_names : Map[String, Unit],
  issues : Array[Json],
) -> Unit {
  match fields.get("network") {
    None | Some(String("wifi")) | Some(String("all")) => ()
    Some(_) =>
      finding(
        issues,
        "invalid-preload-network",
        "\{location}.network",
        "Expected 'wifi' or 'all'.",
      )
  }
  guard fields.get("packages") is Some(Array(packages)) else {
    finding(
      issues,
      "invalid-preload-packages",
      "\{location}.packages",
      "Expected an array of package names or roots.",
    )
    return
  }
  for index, target in packages {
    let target_location = "\{location}.packages[\{index}]"
    match target {
      String(name) if package_names.contains(name) => ()
      String(name) =>
        finding(
          issues,
          "unknown-preload-package",
          target_location,
          "No package has name or root '\{name}'.",
        )
      _ =>
        finding(
          issues, "invalid-preload-package", target_location, "Expected a package name or root string.",
        )
    }
  }
}

///|
fn check_preload_rules(
  manifest : Map[String, Json],
  routes : Map[String, Route],
  issues : Array[Json],
) -> Unit {
  guard manifest.get("preloadRule") is Some(value) else { return }
  guard value is Object(rules) else {
    finding(
      issues, "invalid-preload-rules", "$.preloadRule", "Expected an object keyed by page path.",
    )
    return
  }
  let package_names = preload_package_names(manifest)
  for page, rule in rules {
    let key = Json::string(page).stringify()
    let location = "$.preloadRule[\{key}]"
    if !routes.contains(page) {
      finding(
        issues, "unknown-preload-route", location, "Expected a declared page path.",
      )
    }
    guard rule is Object(fields) else {
      finding(
        issues, "invalid-preload-rule", location, "Expected a preload rule object.",
      )
      continue
    }
    check_preload_rule(fields, location, package_names, issues)
  }
}
