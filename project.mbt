///|
/// The files of a mini program, keyed by `/`-separated path relative to
/// the directory holding `app.json`, with their size in bytes. Contents are
/// loaded on demand through `reader`, which returns None for files that
/// cannot be read as UTF-8 text. Keeping I/O behind a closure lets the
/// whole analysis run against in-memory fixtures in tests.
pub struct Project {
  sizes : Map[String, Int32]
  reader : (String) -> String?
  /// Compiled path -> the source file the developer wrote, for files that
  /// a WeChat DevTools compiler plugin produces (`index.ts` -> `index.js`).
  sources : Map[String, String]
  /// The reverse of `sources`: plugin source -> compiled path.
  outputs : Map[String, String]
}

///|
pub fn Project::new(
  files : Array[(String, Int32)],
  reader : (String) -> String?,
) -> Project {
  let sizes : Map[String, Int32] = Map([])
  for file in files {
    sizes[file.0] = file.1
  }
  { sizes, reader, sources: Map([]), outputs: Map([]), }
}

///|
/// A project backed by a map of file contents; sizes are the UTF-8 length.
pub fn Project::from_sources(sources : Array[(String, String)]) -> Project {
  let contents : Map[String, String] = Map([])
  let files = []
  for source in sources {
    contents[source.0] = source.1
    files.push((source.0, utf8_length(source.1)))
  }
  Project::new(files, fn(path) { contents.get(path) })
}

///|
fn utf8_length(text : String) -> Int32 {
  let mut bytes = 0
  for c in text {
    let code = c.to_int()
    bytes += if code < 0x80 {
      1
    } else if code < 0x800 {
      2
    } else if code < 0x10000 {
      3
    } else {
      4
    }
  }
  bytes
}

///|
pub fn Project::exists(self : Project, path : String) -> Bool {
  self.sizes.contains(path)
}

///|
pub fn Project::size(self : Project, path : String) -> Int32 {
  self.sizes.get(path).unwrap_or(0)
}

///|
/// Limits applied to the packaged size of each package and of the whole
/// mini program. The defaults follow the published WeChat limits: 2 MB for
/// the main package and for each subpackage, 20 MB in total.
pub(all) struct Options {
  max_package_bytes : Int32
  max_total_bytes : Int32
}

///|
pub fn Options::default() -> Options {
  { max_package_bytes: 2 * 1024 * 1024, max_total_bytes: 20 * 1024 * 1024, }
}

///|
/// The source extensions each `useCompilerPlugins` entry of
/// `project.config.json` compiles, and the extension DevTools emits.
fn compiler_rules(plugins : Array[String]) -> Array[(String, String)] {
  let rules = []
  for plugin in plugins {
    match plugin {
      "typescript" => rules.push((".ts", ".js"))
      "less" => rules.push((".less", ".wxss"))
      "sass" => {
        rules.push((".scss", ".wxss"))
        rules.push((".sass", ".wxss"))
      }
      _ => ()
    }
  }
  rules
}

///|
fn compiled_path(path : String, rules : Array[(String, String)]) -> String? {
  if path.has_suffix(".d.ts") {
    return None
  }
  for rule in rules {
    if path.strip_suffix(rule.0) is Some(stem) {
      return Some(stem.to_owned() + rule.1)
    }
  }
  None
}

///|
/// The project as DevTools compiles it with the given compiler plugins
/// (`typescript`, `less`, `sass`): each `a.ts` is analyzed as `a.js` and
/// each `a.less` / `a.scss` / `a.sass` as `a.wxss`, unless the compiled
/// file is already present. Findings name the source file again.
pub fn Project::with_compiler_plugins(
  self : Project,
  plugins : Array[String],
) -> Project {
  let rules = compiler_rules(plugins)
  if rules.is_empty() {
    return self
  }
  let sizes : Map[String, Int32] = Map([])
  let sources : Map[String, String] = Map([])
  for path, size in self.sizes {
    match compiled_path(path, rules) {
      Some(output) if !self.sizes.contains(output) && !sources.contains(output) => {
        sizes[output] = size
        sources[output] = path
      }
      _ => sizes[path] = size
    }
  }
  let outputs : Map[String, String] = Map([])
  for output, source in sources {
    outputs[source] = output
  }
  let reader = self.reader
  {
    sizes,
    reader: fn(path) { reader(sources.get(path).unwrap_or(path)) },
    sources,
    outputs,
  }
}

///|
/// The file the developer wrote for `path`: the plugin source of a
/// compiled file, otherwise `path` itself.
pub fn Project::source_name(self : Project, path : String) -> String {
  self.sources.get(path).unwrap_or(path)
}

///|
/// Maps a reference that names a plugin source (`./util.ts`,
/// `vars.less`) to the compiled file it becomes.
fn Project::compiled_name(self : Project, path : String) -> String {
  self.outputs.get(path).unwrap_or(path)
}
