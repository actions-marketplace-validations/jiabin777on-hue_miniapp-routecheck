///|
test "plugins must be declared, and subpackage plugins stay in their subpackage" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json",
        (
          #|{
          #|  "pages": ["pages/index/index"],
          #|  "plugins": {
          #|    "chart": {"version": "1.2.0", "provider": "wxchart0000000000"},
          #|    "idle": {"version": "dev", "provider": "wxidle00000000000"},
          #|    "broken": {"version": 2}
          #|  },
          #|  "subpackages": [
          #|    {"root": "packageMap", "pages": ["index"],
          #|     "plugins": {"map": {"version": "3.0.0", "provider": "wxmap000000000000"}}},
          #|    {"root": "packageTrip", "pages": ["index"],
          #|     "plugins": {"route": {"version": "3.0.0", "provider": "wxmap000000000000"}}}
          #|  ]
          #|}
        ),
      ),
      ("app.js", "App({})"),
      (
        "pages/index/index.json", "{\"usingComponents\": {\"line\": \"plugin://chart/line\"}}",
      ),
      ("pages/index/index.js", "const map = requirePlugin('map')\nPage({})"),
      ("pages/index/index.wxml", "<line />"),
      (
        "packageMap/index.json",
        (
          #|{"usingComponents": {"route-view": "plugin://route/view"},
          #| "componentPlaceholder": {"route-view": "view"}}
        ),
      ),
      (
        "packageMap/index.js", "const byId = requirePlugin('wxmap000000000000')\nPage({})",
      ),
      (
        "packageMap/index.wxml", "<route-view /><navigator url=\"plugin://ghost/page\" />",
      ),
      ("packageTrip/index.js", "requirePlugin('route')\nPage({})"),
      ("packageTrip/index.wxml", "<view />"),
    ]),
  )
  assert_eq(found(report, include_info=true), [
    ("invalid-plugin", "app.json $.plugins[\"broken\"].version"),
    ("invalid-plugin", "app.json $.plugins[\"broken\"].provider"),
    (
      "duplicate-plugin", "app.json $.subpackages[1].plugins[\"route\"].provider",
    ),
    ("plugin-not-in-package", "pages/index/index.js:1:27"),
    ("unknown-plugin", "packageMap/index.wxml:1:15"),
    ("unused-plugin", "app.json $.plugins[\"idle\"]"),
    ("unused-plugin", "app.json $.plugins[\"broken\"]"),
  ])
}

///|
test "plugins and subpackage plugins must be objects" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json", "{\"pages\": [\"p/index\"], \"plugins\": [], \"subPackages\": [{\"root\": \"s\", \"pages\": [\"index\"], \"plugins\": {\"x\": 1}}]}",
      ),
      ("p/index.js", "Page({})"),
      ("p/index.wxml", ""),
      ("s/index.js", "Page({})"),
      ("s/index.wxml", ""),
    ]),
  )
  assert_eq(found(report), [
    ("invalid-plugins", "app.json $.plugins"),
    ("invalid-plugin", "app.json $.subPackages[0].plugins[\"x\"]"),
  ])
}

///|
test "worker code stays in the workers directory" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json", "{\"pages\": [\"pages/index/index\"], \"workers\": {\"path\": \"workers/\", \"isSubpackage\": true}}",
      ),
      ("app.js", "App({})"),
      (
        "pages/index/index.js",
        (
          #|const ok = wx.createWorker('workers/request/index.js')
          #|const absolute = wx.createWorker('/workers/request/index.js')
          #|const missing = wx.createWorker('workers/request/main.js')
          #|const outside = wx.createWorker('utils/net.js')
          #|Page({})
        ),
      ),
      ("pages/index/index.wxml", "<view />"),
      (
        "workers/request/index.js", "const u = require('./utils')\nconst net = require('../../utils/net')",
      ),
      ("workers/request/utils.js", "module.exports = {}"),
      ("workers/request/icon.png", "png"),
      ("utils/net.js", "module.exports = {}"),
    ]),
  )
  assert_eq(found(report), [
    ("invalid-worker-file", "workers/request/icon.png"),
    ("worker-dependency-outside-directory", "workers/request/index.js:2:21"),
    ("unresolved-worker", "pages/index/index.js:3:33"),
    ("worker-outside-directory", "pages/index/index.js:4:33"),
  ])
  // Worker files are entry points, not unreferenced files.
  assert_true(
    report.findings
    .iter()
    .all(fn(f) {
      !f.file.has_prefix("workers/") || f.code != "unreferenced-file"
    }),
  )
}

///|
test "workers configuration problems" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json", "{\"pages\": [\"p/index\"], \"workers\": {\"path\": \"jobs\", \"isSubpackage\": \"yes\"}}",
      ),
      ("p/index.js", "Page({})"),
      ("p/index.wxml", ""),
    ]),
  )
  assert_eq(found(report), [
    ("invalid-workers", "app.json $.workers.isSubpackage"),
    ("missing-workers-directory", "app.json $.workers"),
  ])
  let report = @routecheck.analyze(
    project([
      ("app.json", "{\"pages\": [\"p/index\"], \"workers\": \"../w\"}"),
      ("p/index.js", "wx.createWorker('w/index.js')\nPage({})"),
      ("p/index.wxml", ""),
    ]),
  )
  assert_eq(found(report), [
    ("invalid-workers", "app.json $.workers"),
    ("worker-outside-directory", "p/index.js:1:17"),
  ])
}

///|
test "entranceDeclare opens a declared page" {
  let check = fn(entrance : String) {
    found(
      @routecheck.analyze(
        project([
          (
            "app.json",
            "{\"pages\": [\"pages/index/index\", \"pages/map/index\"], \"entranceDeclare\": \{entrance}}",
          ),
          ("pages/index/index.js", "Page({})"),
          ("pages/index/index.wxml", ""),
          ("pages/map/index.js", "Page({})"),
          ("pages/map/index.wxml", ""),
        ]),
      ),
    )
  }
  assert_eq(
    check(
      "{\"locationMessage\": {\"path\": \"pages/map/index\", \"query\": \"foo=bar\"}}",
    ),
    [],
  )
  assert_eq(
    check(
      "{\"locationMessage\": {\"path\": \"/pages/map/index\", \"query\": 1}}",
    ),
    [
      (
        "unknown-entrance-route", "app.json $.entranceDeclare.locationMessage.path",
      ),
      (
        "invalid-entrance-declare", "app.json $.entranceDeclare.locationMessage.query",
      ),
    ],
  )
  assert_eq(check("{\"locationMessage\": {}}"), [
    (
      "invalid-entrance-declare", "app.json $.entranceDeclare.locationMessage.path",
    ),
  ])
  assert_eq(check("[]"), [
    ("invalid-entrance-declare", "app.json $.entranceDeclare"),
  ])
}
