///|
fn resolution_text(resolution : Resolution) -> String {
  match resolution {
    Found(path) => "found " + path
    External => "external"
    Missing(path) => "missing " + path
    Escapes => "escapes"
  }
}

///|
test "path normalization" {
  assert_eq(normalize_path("/a/./b/../c"), Some("a/c"))
  assert_eq(normalize_path("a//b/"), Some("a/b"))
  assert_eq(normalize_path("a/../../b"), None)
  assert_eq(dirname("a/b/c.js"), "a/b")
  assert_eq(dirname("c.js"), "")
  assert_eq(extension("a.b/c"), "")
  assert_eq(extension("dir/.hidden"), "")
  assert_eq(extension("x/Logo.PNG"), ".png")
  assert_eq(strip_extension("pages/a/index.json"), "pages/a/index")
}

///|
test "script resolution: extensions, index files, root and npm lookups" {
  let project = Project::from_sources([
    ("utils/a.js", ""),
    ("utils/lib/index.js", ""),
    ("miniprogram_npm/dayjs/index.js", ""),
    ("sub/miniprogram_npm/dayjs/index.js", ""),
    ("miniprogram_npm/@vant/weapp/button/index.json", ""),
  ])
  let resolve = fn(dir, spec) {
    resolution_text(resolve_reference(project, dir, spec, script_lookup))
  }
  assert_eq(resolve("pages/x", "../../utils/a"), "found utils/a.js")
  assert_eq(resolve("pages/x", "/utils/a.js"), "found utils/a.js")
  assert_eq(resolve("utils", "./lib"), "found utils/lib/index.js")
  assert_eq(resolve("pages/x", "dayjs"), "found miniprogram_npm/dayjs/index.js")
  // The nearest miniprogram_npm wins, as in the WeChat npm build.
  assert_eq(
    resolve("sub/page", "dayjs"),
    "found sub/miniprogram_npm/dayjs/index.js",
  )
  assert_eq(resolve("utils", "a"), "found utils/a.js")
  assert_eq(resolve("utils", "./nope?x=1"), "missing utils/nope")
  assert_eq(resolve("utils", "../../out"), "escapes")
  assert_eq(resolve("utils", "https://x/y.js"), "external")
  assert_eq(
    resolution_text(
      resolve_component(project, "pages/a", "@vant/weapp/button/index"),
    ),
    "found miniprogram_npm/@vant/weapp/button/index",
  )
}

///|
test "Tarjan finds every strongly connected component exactly once" {
  let successors : Map[String, Array[String]] = Map([
    ("a", ["b"]),
    ("b", ["c", "d"]),
    ("c", ["a"]),
    ("d", ["e"]),
    ("e", ["d", "f"]),
    ("f", []),
    ("g", ["g"]),
  ])
  let components = strongly_connected(
    ["a", "b", "c", "d", "e", "f", "g"],
    successors,
  ).map(fn(c) {
    c.sort()
    c
  })
  assert_eq(components, [["f"], ["d", "e"], ["a", "b", "c"], ["g"]])
}

///|
test "Tarjan handles long chains without recursion" {
  let nodes = Array::makei(20000, fn(i) { "n\{i}" })
  let successors : Map[String, Array[String]] = Map([])
  for i, node in nodes {
    successors[node] = if i + 1 < nodes.length() {
      [nodes[i + 1]]
    } else {
      [nodes[0]]
    }
  }
  let components = strongly_connected(nodes, successors)
  assert_eq(components.length(), 1)
  assert_eq(components[0].length(), 20000)
}
