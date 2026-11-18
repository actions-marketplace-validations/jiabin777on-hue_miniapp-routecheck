///|
fn plan(
  report : @routecheck.Report,
) -> Array[(String, String, Bool, Array[(String, String, String)])] {
  report.moves.map(fn(m) {
    (
      m.file,
      m.to,
      m.conflict,
      m.rewrites.map(fn(r) { (r.where_(), r.specifier, r.replacement) }),
    )
  })
}

///|
test "migration plan for files only one subpackage uses" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json", "{\"pages\": [\"pages/index/index\"], \"subpackages\": [{\"root\": \"pkg\", \"pages\": [\"home/index\"]}]}",
      ),
      ("pages/index/index.js", "require('../../utils/shared')\nPage({})"),
      ("pages/index/index.wxml", "<view />"),
      (
        "pages/index/index.wxss", "@import \"../../components/badge/index.wxss\";",
      ),
      (
        "pkg/home/index.json", "{\"usingComponents\": {\"card\": \"/components/card/index\", \"badge\": \"../../components/badge/index\"}}",
      ),
      (
        "pkg/home/index.js",
        (
          #|const format = require('../../utils/format')
          #|const abs = require('/utils/abs.js')
          #|const lib = require('lib')
          #|Page({})
        ),
      ),
      (
        "pkg/home/index.wxml", "<card /><badge /><image src=\"/images/banner.png\" />",
      ),
      ("pkg/home/index.wxss", "@import \"../../styles/theme.wxss\";"),
      ("pkg/utils/abs.js", "module.exports = 'already here'"),
      ("utils/format.js", "require('./shared')\nrequire('./helper')"),
      ("utils/helper.js", "module.exports = {}"),
      ("utils/abs.js", "module.exports = {}"),
      ("utils/shared.js", "module.exports = {}"),
      ("styles/theme.wxss", ".a {}"),
      ("images/banner.png", "png"),
      ("images/card.png", "png"),
      ("components/card/index.json", component_json),
      ("components/card/index.js", component),
      ("components/card/index.wxml", "<image src=\"../../images/card.png\" />"),
      ("components/card/index.wxss", ".card {}"),
      // The badge's style is also used by a main package page, so the
      // component cannot move as a whole.
      ("components/badge/index.json", component_json),
      ("components/badge/index.js", component),
      ("components/badge/index.wxml", "<view />"),
      ("components/badge/index.wxss", ".badge {}"),
      ("miniprogram_npm/lib/index.js", "module.exports = {}"),
    ]),
  )
  assert_eq(plan(report), [
    ("components/card/index.js", "pkg/components/card/index.js", false, []),
    (
      "components/card/index.json",
      "pkg/components/card/index.json",
      false,
      [
        (
          "pkg/home/index.json $.usingComponents[\"card\"]", "/components/card/index",
          "/pkg/components/card/index",
        ),
      ],
    ),
    ("components/card/index.wxml", "pkg/components/card/index.wxml", false, []),
    ("components/card/index.wxss", "pkg/components/card/index.wxss", false, []),
    (
      "images/banner.png",
      "pkg/images/banner.png",
      false,
      [
        (
          "pkg/home/index.wxml:1:18", "/images/banner.png", "/pkg/images/banner.png",
        ),
      ],
    ),
    ("images/card.png", "pkg/images/card.png", false, []),
    (
      "styles/theme.wxss",
      "pkg/styles/theme.wxss",
      false,
      [
        (
          "pkg/home/index.wxss:1:1", "../../styles/theme.wxss", "../styles/theme.wxss",
        ),
      ],
    ),
    (
      "utils/abs.js",
      "pkg/utils/abs.js",
      true,
      [("pkg/home/index.js:2:21", "/utils/abs.js", "/pkg/utils/abs.js")],
    ),
    (
      "utils/format.js",
      "pkg/utils/format.js",
      false,
      [
        ("pkg/home/index.js:1:24", "../../utils/format", "../utils/format"),
        ("utils/format.js:1:9", "./shared", "../../utils/shared"),
      ],
    ),
    ("utils/helper.js", "pkg/utils/helper.js", false, []),
  ])
  // The suggestions themselves still cover every such file.
  assert_true(
    report.findings
    .iter()
    .any(fn(f) {
      f.code == "move-to-subpackage" && f.file == "components/badge/index.js"
    }),
  )
}

///|
test "relative references are rebuilt from the new location" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json", "{\"pages\": [\"p/index\"], \"subpackages\": [{\"root\": \"sub/deep\", \"pages\": [\"a/index\"]}]}",
      ),
      ("p/index.js", "Page({})"),
      ("p/index.wxml", ""),
      ("sub/deep/a/index.js", "require('../../../lib/x')\nPage({})"),
      ("sub/deep/a/index.wxml", ""),
      ("lib/x.js", "require('y')"),
      ("lib/y.js", ""),
    ]),
  )
  assert_eq(plan(report), [
    (
      "lib/x.js",
      "sub/deep/lib/x.js",
      false,
      [("sub/deep/a/index.js:1:9", "../../../lib/x", "../lib/x")],
    ),
    ("lib/y.js", "sub/deep/lib/y.js", false, []),
  ])
}
