// Migration plan for move-to-subpackage

///|
/// One reference to update when files move into a subpackage. `file` and
/// `line`/`column` (or `location`, a JSON path) say where it is written.
#derive(Eq, Debug)
pub(all) struct Rewrite {
  file : String
  location : String
  line : Int32
  column : Int32
  /// The reference as written today.
  specifier : String
  /// The reference to write after the move; empty when it cannot be
  /// computed and needs a manual update.
  replacement : String
}

///|
/// A main-package file that only one subpackage uses, where to move it,
/// and every reference that changes with the move.
#derive(Eq, Debug)
pub(all) struct Move {
  file : String
  to : String
  package_name : String
  bytes : Int32
  /// A file already exists at `to`.
  conflict : Bool
  /// References to `file` from other files, and references written in
  /// `file` whose relative path breaks once it moves.
  rewrites : Array[Rewrite]
}

///|
pub fn Rewrite::where_(self : Rewrite) -> String {
  if self.line > 0 {
    "\{self.file}:\{self.line}:\{self.column}"
  } else {
    "\{self.file} \{self.location}"
  }
}

///|
fn Rewrite::to_json(self : Rewrite) -> Json {
  let fields : Map[String, Json] = { "file": Json::string(self.file) }
  if self.location != "" {
    fields["location"] = Json::string(self.location)
  }
  if self.line > 0 {
    fields["line"] = Json::number(self.line.to_double())
    fields["column"] = Json::number(self.column.to_double())
  }
  fields["specifier"] = Json::string(self.specifier)
  fields["replacement"] = Json::string(self.replacement)
  Json::object(fields)
}

///|
fn Move::to_json(self : Move) -> Json {
  {
    "file": Json::string(self.file),
    "to": Json::string(self.to),
    "package": Json::string(self.package_name),
    "bytes": Json::number(self.bytes.to_double()),
    "conflict": Json::boolean(self.conflict),
    "rewrites": Json::array(self.rewrites.map(fn(r) { r.to_json() })),
  }
}

///|
/// The shortest `./` or `../` reference from `directory` to `target`.
fn relative_specifier(directory : String, target : String) -> String {
  let from = if directory == "" {
    []
  } else {
    directory.split("/").map(fn(s) { s.to_owned() }).collect()
  }
  let to : Array[String] = target
    .split("/")
    .map(fn(s) { s.to_owned() })
    .collect()
  let mut common = 0
  while common < from.length() &&
        common < to.length() - 1 &&
        from[common] == to[common] {
    common += 1
  }
  let parts = Array::make(from.length() - common, "..")
  for index in common..<to.length() {
    parts.push(to[index])
  }
  let text = parts.join("/")
  if text.has_prefix("../") {
    text
  } else {
    "./" + text
  }
}

///|
/// The path a reference spells out before extension probing, and whether
/// it is written from the mini program root.
fn written_path(specifier : String, directory : String) -> (String, Bool)? {
  if specifier == "" || is_external(specifier) {
    return None
  }
  if specifier.has_prefix("/") {
    normalize_path(specifier).map(fn(path) { (path, true) })
  } else {
    normalize_path(join_path(directory, specifier)).map(fn(path) {
      (path, false)
    })
  }
}

///|
/// Plans the `move-to-subpackage` suggestions: each file keeps its path
/// under the subpackage root. A page or component moves only as a whole,
/// and files in `miniprogram_npm` are left to the npm build.
fn Analyzer::plan_moves(
  self : Analyzer,
  candidates : Array[(String, Int32)],
) -> Array[Move] {
  let destination : Map[String, String] = Map([])
  let package_of : Map[String, Int32] = Map([])
  for candidate in candidates {
    let (file, index) = candidate
    if file.has_prefix("miniprogram_npm/") || file.contains("/miniprogram_npm/") {
      continue
    }
    destination[file] = self.packages[index].root + "/" + file
    package_of[file] = index
  }
  // The base path of a component or page names its files together.
  for base, _ in self.units {
    let files = [".json", ".js", ".wxml", ".wxss"]
      .map(fn(ext) { base + ext })
      .filter(fn(path) { self.project.exists(path) })
    let moving = files.filter(fn(path) { destination.contains(path) })
    if moving.is_empty() {
      continue
    }
    let index = package_of[moving[0]]
    if moving.length() == files.length() &&
      moving.iter().all(fn(path) { package_of[path] == index }) {
      destination[base] = self.packages[index].root + "/" + base
      package_of[base] = index
    } else {
      for path in moving {
        destination.remove(path)
      }
    }
  }
  // Rewrites are listed under the moved file: a unit's under its .json.
  let key_of = fn(node : String) -> String {
    if self.project.exists(node) {
      node
    } else {
      node + ".json"
    }
  }
  let rewrites : Map[String, Array[Rewrite]] = Map([])
  let source = fn(path : String) { self.project.source_name(path) }
  for edge in self.edges {
    if edge.kind is PageFile {
      continue
    }
    let target_moves = destination.contains(edge.to)
    let source_moves = destination.contains(edge.file)
    if !target_moves && !source_moves {
      continue
    }
    let key = key_of(if target_moves { edge.to } else { edge.file })
    let new_directory = dirname(destination.get(edge.file).unwrap_or(edge.file))
    let new_target = destination.get(edge.to).unwrap_or(edge.to)
    let replacement = match written_path(edge.specifier, dirname(edge.file)) {
      Some((written, absolute)) if edge.to.has_prefix(written) &&
        (
          written.length() == edge.to.length() ||
          edge.to[written.length():].has_prefix(".") ||
          edge.to[written.length():].has_prefix("/")
        ) => {
        // Keep what the reference leaves out, such as `.js` or `/index`.
        let omitted = edge.to.length() - written.length()
        let new_written = new_target[:new_target.length() - omitted].to_owned()
        let still_resolves = if absolute {
          written == new_written
        } else {
          normalize_path(join_path(new_directory, edge.specifier)) ==
          Some(new_written)
        }
        if still_resolves {
          continue
        }
        if absolute {
          "/" + new_written
        } else {
          relative_specifier(new_directory, new_written)
        }
      }
      // A bare npm-style reference keeps working from a deeper directory.
      _ if !target_moves => continue
      _ => ""
    }
    let rewrite : Rewrite = {
      file: source(edge.file),
      location: edge.location,
      line: edge.line,
      column: edge.column,
      specifier: edge.specifier,
      replacement,
    }
    match rewrites.get(key) {
      Some(list) => list.push(rewrite)
      None => rewrites[key] = [rewrite]
    }
  }
  let moves = []
  for candidate in candidates {
    let (file, index) = candidate
    guard destination.get(file) is Some(to) else { continue }
    let source_file = source(file)
    let source_to = self.packages[index].root + "/" + source_file
    moves.push({
      file: source_file,
      to: source_to,
      package_name: self.packages[index].name,
      bytes: self.project.size(file),
      conflict: self.project.exists(to) || self.project.exists(source_to),
      rewrites: rewrites.get(file).unwrap_or([]),
    })
  }
  moves
}
