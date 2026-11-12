///|
test "preload triggers and targets resolve main, subpackage root and alias" {
  let manifest =
    #|{
    #|  "pages": ["home"],
    #|  "subPackages": [{"root":"pkg","name":"detail","pages":["view"],"independent":true}],
    #|  "preloadRule": {
    #|    "home":{"network":"wifi","packages":["detail"]},
    #|    "pkg/view":{"packages":["__APP__","pkg"]}
    #|  }
    #|}
  let files = ["home.js", "home.wxml", "pkg/view.js", "pkg/view.wxml"]
  assert_true(issue_keys(@routecheck.audit_manifest(manifest, files)).is_empty())
}

///|
test "preload diagnostics locate bad triggers, network and individual targets" {
  let manifest =
    #|{
    #|  "pages": ["home"],
    #|  "preloadRule": {
    #|    "missing\"page":{"network":"mobile","packages":["missing",42]}
    #|  }
    #|}
  assert_eq(
    issue_keys(@routecheck.audit_manifest(manifest, ["home.js", "home.wxml"])),
    [
      ("unknown-preload-route", "$.preloadRule[\"missing\\\"page\"]"),
      ("invalid-preload-network", "$.preloadRule[\"missing\\\"page\"].network"),
      ("unknown-preload-package", "$.preloadRule[\"missing\\\"page\"].packages[0]"),
      ("invalid-preload-package", "$.preloadRule[\"missing\\\"page\"].packages[1]"),
    ],
  )
}

///|
test "preload rules reject wrong container and missing packages" {
  let files = ["home.js", "home.wxml"]
  let bad_map = #|{"pages":["home"],"preloadRule":[]}
  let bad_rule = #|{"pages":["home"],"preloadRule":{"home":false}}
  let no_packages = #|{"pages":["home"],"preloadRule":{"home":{"network":"all"}}}
  assert_eq(issue_keys(@routecheck.audit_manifest(bad_map, files)), [
    ("invalid-preload-rules", "$.preloadRule"),
  ])
  assert_eq(issue_keys(@routecheck.audit_manifest(bad_rule, files)), [
    ("invalid-preload-rule", "$.preloadRule[\"home\"]"),
  ])
  assert_eq(issue_keys(@routecheck.audit_manifest(no_packages, files)), [
    ("invalid-preload-packages", "$.preloadRule[\"home\"].packages"),
  ])
}
