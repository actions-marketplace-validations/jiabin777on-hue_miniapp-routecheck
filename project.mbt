///|
/// The files of a mini program, keyed by `/`-separated path relative to
/// the directory holding `app.json`, with their size in bytes. Contents are
/// loaded on demand through `reader`, which returns None for files that
/// cannot be read as UTF-8 text. Keeping I/O behind a closure lets the
/// whole analysis run against in-memory fixtures in tests.
pub struct Project {
  sizes : Map[String, Int32]
  reader : (String) -> String?
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
  { sizes, reader, }
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
