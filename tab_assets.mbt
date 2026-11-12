///|
fn check_tab_icon(
  icon : Json?,
  location : String,
  dark_mode : Bool,
  paths : Map[String, Unit],
  issues : Array[Json],
) -> Unit {
  guard icon is Some(value) else { return }
  guard value is String(reference) else {
    finding(issues, "invalid-tab-icon-path", location, "Expected a local icon path string.")
    return
  }
  if dark_mode &&
    reference.has_prefix("@") &&
    reference.length() > 1 &&
    !reference.contains_any(chars="/\\") &&
    is_safe_path(reference) {
    return
  }
  let path = match (reference.strip_prefix("./"), reference.strip_prefix("/")) {
    (Some(relative), _) | (None, Some(relative)) => relative.to_owned()
    (None, None) => reference
  }
  if !is_safe_path(path) {
    finding(
      issues,
      "invalid-tab-icon-path",
      location,
      "Expected a local icon path inside the mini program directory.",
    )
  } else if !paths.contains(path) {
    finding(issues, "missing-tab-icon-file", location, path)
  }
}

///|
fn check_tab_bar_assets(
  manifest : Map[String, Json],
  paths : Map[String, Unit],
  issues : Array[Json],
) -> Unit {
  guard manifest.get("tabBar") is Some(Object(tab_bar)) &&
    tab_bar.get("list") is Some(Array(tabs)) else {
    return
  }
  if tab_bar.get("custom") is Some(True) ||
    tab_bar.get("position") is Some(String("top")) {
    return
  }
  let dark_mode = manifest.get("darkmode") is Some(True)
  for index, tab in tabs {
    guard tab is Object(fields) else { continue }
    for field in ["iconPath", "selectedIconPath"] {
      check_tab_icon(
        fields.get(field),
        "$.tabBar.list[\{index}].\{field}",
        dark_mode,
        paths,
        issues,
      )
    }
  }
}
