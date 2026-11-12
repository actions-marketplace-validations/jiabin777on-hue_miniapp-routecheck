///|
fn issue_keys(report : Json) -> Array[(String, String)] {
  guard report is Array(items) else { panic() }
  items.map(fn(item) {
    guard item is Object(fields) &&
      fields.get("code") is Some(String(code)) &&
      fields.get("location") is Some(String(location)) else {
      panic()
    }
    (code, location)
  })
}

///|
test "valid main pages and camel-case subpackage declaration" {
  let manifest =
    #|{
    #|  "pages": ["pages/home", "pages/about"],
    #|  "entryPagePath": "pages/home",
    #|  "subPackages": [{"root": "package/info", "pages": ["index"]}],
    #|  "tabBar": {"list": [{"pagePath": "pages/home"}, {"pagePath": "pages/about"}]}
    #|}
  let files = [
    "pages/home.js", "pages/home.wxml", "pages/about.js", "pages/about.wxml", "package/info/index.js",
    "package/info/index.wxml",
  ]
  assert_true(
    issue_keys(@routecheck.audit_manifest(manifest, files)).is_empty(),
  )
}

///|
test "malformed manifests and duplicate JSON keys are reported" {
  assert_eq(issue_keys(@routecheck.audit_manifest("{", [])), [
    ("invalid-json", "$"),
  ])
  assert_eq(issue_keys(@routecheck.audit_manifest("[]", [])), [
    ("invalid-manifest", "$"),
  ])
  assert_eq(
    issue_keys(
      @routecheck.audit_manifest("{\"pages\":[],\"pages\":[\"home\"]}", []),
    ),
    [("invalid-json", "$")],
  )
}

///|
test "unsafe paths get only route diagnostics" {
  let manifest =
    #|{"pages":["", "/absolute", "../parent", "page//file", "page\\file", "page.js", "page?draft=1"]}
  let expected = Array::makei(7, fn(index) {
    ("invalid-route", "$.pages[\{index}]")
  })
  assert_eq(issue_keys(@routecheck.audit_manifest(manifest, [])), expected)
}

///|
test "case differences and duplicate routes are detected" {
  let manifest =
    #|{"pages":["Home", "home", "Home"]}
  let files = ["Home.js", "Home.wxml", "home.js", "home.wxml"]
  assert_eq(issue_keys(@routecheck.audit_manifest(manifest, files)), [
    ("route-case-collision", "$.pages[1]"),
    ("duplicate-route", "$.pages[2]"),
  ])
}

///|
test "nested subpackage root and invalid references are distinct" {
  let manifest =
    #|{
    #|  "pages": ["home"],
    #|  "entryPagePath": "home?draft=1",
    #|  "subpackages": [{"root":"pkg","pages":["one"]},{"root":"pkg/child","pages":["two"]}],
    #|  "tabBar": {"list":[{"pagePath":"home"},{"pagePath":"pkg/one"}]}
    #|}
  let files = [
    "home.js", "home.wxml", "pkg/one.js", "pkg/one.wxml", "pkg/child/two.js", "pkg/child/two.wxml",
  ]
  assert_eq(issue_keys(@routecheck.audit_manifest(manifest, files)), [
    ("overlapping-subpackage-root", "$.subpackages[1].root"),
    ("unknown-entry-route", "$.entryPagePath"),
    ("tab-route-not-in-main-package", "$.tabBar.list[1].pagePath"),
  ])
}

///|
test "page files must match exact case and optional files are unnecessary" {
  let manifest = "{\"pages\":[\"Home\"]}"
  assert_eq(
    issue_keys(@routecheck.audit_manifest(manifest, ["Home.wxml", "home.js"])),
    [("missing-page-file", "$.pages[0]")],
  )
  assert_true(
    issue_keys(@routecheck.audit_manifest(manifest, ["Home.wxml", "Home.js"])).is_empty(),
  )
}
