///|
/// Collapses `.` and `..` segments of a `/`-separated path relative to the
/// mini program root. A leading `/` means the root itself. Returns None
/// when the path climbs above the root.
fn normalize_path(path : String) -> String? {
  let parts : Array[String] = []
  for part in path.split("/") {
    match part.to_owned() {
      "" | "." => ()
      ".." => {
        guard parts.pop() is Some(_) else { return None }
      }
      segment => parts.push(segment)
    }
  }
  Some(parts.join("/"))
}

///|
fn dirname(path : String) -> String {
  match path.rev_find("/") {
    Some(index) => path[:index].to_owned()
    None => ""
  }
}

///|
fn join_path(directory : String, relative : String) -> String {
  if directory == "" {
    relative
  } else {
    directory + "/" + relative
  }
}

///|
/// Lower-case extension including the dot, or "" when there is none.
fn extension(path : String) -> String {
  let name = match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
  match name.rev_find(".") {
    Some(index) if index > 0 => name[index:].to_owned().to_lower()
    _ => ""
  }
}

///|
fn strip_extension(path : String) -> String {
  let ext = extension(path)
  path[:path.length() - ext.length()].to_owned()
}

///|
/// References that point outside the local file tree: network resources,
/// plugins, cloud files and values computed by data bindings.
fn is_external(reference : String) -> Bool {
  reference.contains("{{") ||
  [
    "http://", "https://", "//", "data:", "plugin://", "plugin-private://", "cloud://",
    "wxfile://",
  ]
  .iter()
  .any(fn(prefix) { reference.has_prefix(prefix) })
}

///|
/// Whether a file lives under the directory `root` ("" is the whole tree).
fn is_under(path : String, root : String) -> Bool {
  root == "" || path.has_prefix(root + "/")
}

///|
fn min_int(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn max_int(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}
