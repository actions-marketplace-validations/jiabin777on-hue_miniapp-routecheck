///|
test "tab icons resolve local paths with optional root or dot prefixes" {
  let manifest =
    #|{
    #|  "pages": ["home", "about"],
    #|  "tabBar": {"list": [
    #|    {"pagePath":"home","iconPath":"/assets/home.png","selectedIconPath":"./assets/active.png"},
    #|    {"pagePath":"about"}
    #|  ]}
    #|}
  let files = [
    "home.js", "home.wxml", "about.js", "about.wxml", "assets/home.png", "assets/active.png",
  ]
  assert_true(
    issue_keys(@routecheck.audit_manifest(manifest, files)).is_empty(),
  )
}

///|
test "tab icon diagnostics distinguish invalid paths from missing files" {
  let manifest =
    #|{
    #|  "pages": ["home", "about"],
    #|  "tabBar": {"list": [
    #|    {"pagePath":"home","iconPath":"https://example.com/home.png","selectedIconPath":"../outside.png"},
    #|    {"pagePath":"about","iconPath":"assets/About.png","selectedIconPath":false}
    #|  ]}
    #|}
  let files = [
    "home.js", "home.wxml", "about.js", "about.wxml", "assets/about.png",
  ]
  assert_eq(issue_keys(@routecheck.audit_manifest(manifest, files)), [
    ("invalid-tab-icon-path", "$.tabBar.list[0].iconPath"),
    ("invalid-tab-icon-path", "$.tabBar.list[0].selectedIconPath"),
    ("missing-tab-icon-file", "$.tabBar.list[1].iconPath"),
    ("invalid-tab-icon-path", "$.tabBar.list[1].selectedIconPath"),
  ])
}

///|
test "custom and top tab bars skip native icon file checks" {
  let custom =
    #|{"pages":["home","about"],"tabBar":{"custom":true,"list":[{"pagePath":"home","iconPath":"missing.png"},{"pagePath":"about"}]}}
  let top =
    #|{"pages":["home","about"],"tabBar":{"position":"top","list":[{"pagePath":"home","iconPath":"missing.png"},{"pagePath":"about"}]}}
  let files = ["home.js", "home.wxml", "about.js", "about.wxml"]
  assert_true(issue_keys(@routecheck.audit_manifest(custom, files)).is_empty())
  assert_true(issue_keys(@routecheck.audit_manifest(top, files)).is_empty())
}

///|
test "dark mode theme variables are distinct from direct tab icon paths" {
  let manifest =
    #|{
    #|  "pages": ["home", "about"],
    #|  "darkmode": true,
    #|  "themeLocation": "theme.json",
    #|  "tabBar": {"list": [
    #|    {"pagePath":"home","iconPath":"@iconPath","selectedIconPath":"@assets/selected.png"},
    #|    {"pagePath":"about"}
    #|  ]}
    #|}
  let files = ["home.js", "home.wxml", "about.js", "about.wxml", "theme.json"]
  assert_eq(issue_keys(@routecheck.audit_manifest(manifest, files)), [
    ("missing-tab-icon-file", "$.tabBar.list[0].selectedIconPath"),
  ])
}
