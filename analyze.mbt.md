# Using the analyzer as a library

`analyze` does no I/O: a `Project` lists file sizes and reads contents
through a closure, so it can run on any MoonBit backend against files held
in memory, a zip archive or a virtual file system.

```mbt check
///|
test "analyze an in-memory mini program" {
  let project = @routecheck.Project::from_sources([
    (
      "app.json", "{\"pages\": [\"pages/index/index\"], \"subpackages\": [{\"root\": \"pkg\", \"pages\": [\"a/index\"]}]}",
    ),
    ("app.js", "App({})"),
    ("pages/index/index.js", "const f = require('../../pkg/util.js')\nPage({})"),
    ("pages/index/index.wxml", "<view />"),
    ("pkg/a/index.js", "Page({})"),
    ("pkg/a/index.wxml", "<view />"),
    ("pkg/util.js", "module.exports = {}"),
  ])
  let report = @routecheck.analyze(project)
  assert_eq(report.findings.map(fn(f) { (f.code, f.where_()) }), [
    ("main-package-references-subpackage", "pages/index/index.js:1:19"),
  ])
}
```
