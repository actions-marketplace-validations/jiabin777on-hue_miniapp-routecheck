///|
priv enum Resolution {
  Found(String)
  /// Network, plugin, cloud or data-bound reference; not checked.
  External
  /// No candidate exists; carries the normalized path that was expected.
  Missing(String)
  /// The path climbs above the mini program root.
  Escapes
}

///|
/// How a reference is looked up. `extensions` are appended when the
/// reference has none of them; an empty list means the path must name an
/// existing file exactly (images and other assets).
priv struct Lookup {
  extensions : Array[String]
  /// Try `<path>/index<ext>` after `<path><ext>`.
  index : Bool
  /// Search `miniprogram_npm` in the importer's directory and its parents
  /// for bare specifiers such as `@vant/weapp/button/index`.
  npm : Bool
}

///|
fn probe(project : Project, base : String, lookup : Lookup) -> String? {
  if project.exists(base) &&
    (
      lookup.extensions.is_empty() ||
      lookup.extensions.contains(extension(base))
    ) {
    return Some(base)
  }
  for ext in lookup.extensions {
    if project.exists(base + ext) {
      return Some(base + ext)
    }
  }
  if lookup.index {
    for ext in lookup.extensions {
      let candidate = join_path(base, "index" + ext)
      if project.exists(candidate) {
        return Some(candidate)
      }
    }
  }
  None
}

///|
fn is_relative_specifier(reference : String) -> Bool {
  reference == "." ||
  reference == ".." ||
  reference.has_prefix("./") ||
  reference.has_prefix("../")
}

///|
/// Resolves `reference` written in a file inside `directory`.
///
/// - `/a/b` is relative to the mini program root;
/// - `./a` and `../a` are relative to `directory`;
/// - a bare `a/b` is first looked up in `miniprogram_npm` (when enabled),
///   then relative to `directory`, matching how the WeChat compiler treats
///   paths without a leading `./`.
fn resolve_reference(
  project : Project,
  directory : String,
  reference : String,
  lookup : Lookup,
) -> Resolution {
  if is_external(reference) {
    return External
  }
  // Query strings and fragments are not part of a file path.
  let reference = match reference.find("?") {
    Some(index) => reference[:index].to_owned()
    None => reference
  }
  if reference.has_prefix("/") {
    guard normalize_path(reference) is Some(base) else { return Escapes }
    return match probe(project, base, lookup) {
      Some(found) => Found(found)
      None => Missing(base)
    }
  }
  if lookup.npm && !is_relative_specifier(reference) {
    let mut current = Some(directory)
    while current is Some(dir) {
      if normalize_path(join_path(join_path(dir, "miniprogram_npm"), reference))
        is Some(base) &&
        probe(project, base, lookup) is Some(found) {
        return Found(found)
      }
      current = if dir == "" { None } else { Some(dirname(dir)) }
    }
  }
  guard normalize_path(join_path(directory, reference)) is Some(base) else {
    return Escapes
  }
  match probe(project, base, lookup) {
    Some(found) => Found(found)
    None => Missing(base)
  }
}

///|
let script_lookup : Lookup = { extensions: [".js"], index: true, npm: true, }

///|
let wxs_lookup : Lookup = { extensions: [".wxs"], index: false, npm: false, }

///|
let wxml_lookup : Lookup = { extensions: [".wxml"], index: false, npm: false, }

///|
let wxss_lookup : Lookup = { extensions: [".wxss"], index: false, npm: false, }

///|
let asset_lookup : Lookup = { extensions: [], index: false, npm: false, }

///|
let component_lookup : Lookup = {
  extensions: [".json"],
  index: true,
  npm: true,
}

///|
/// Resolves a `usingComponents` value to the component's base path (its
/// files without extension). A component is identified by its `.json`.
fn resolve_component(
  project : Project,
  directory : String,
  reference : String,
) -> Resolution {
  match resolve_reference(project, directory, reference, component_lookup) {
    Found(json) => Found(strip_extension(json))
    other => other
  }
}
