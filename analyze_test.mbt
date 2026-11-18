///|
fn project(files : Array[(String, String)]) -> @routecheck.Project {
  @routecheck.Project::from_sources(files)
}

///|
/// (code, where) pairs, ignoring informational findings unless asked.
fn found(
  report : @routecheck.Report,
  include_info~ : Bool = false,
) -> Array[(String, String)] {
  report.findings
  .filter(fn(f) { include_info || f.severity != Info })
  .map(fn(f) { (f.code, f.where_()) })
}

///|
let page : String = "Page({})"

///|
let component : String = "Component({})"

///|
let component_json : String = "{\"component\": true}"

///|
test "a well-formed project with components, npm, templates and wxs is clean" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json",
        (
          #|{
          #|  "pages": ["pages/home/index", "pages/me/index"],
          #|  "subpackages": [{"root": "shop", "pages": ["list/index"]}],
          #|  "tabBar": {"list": [
          #|    {"pagePath": "pages/home/index", "iconPath": "images/home.png"},
          #|    {"pagePath": "pages/me/index"}
          #|  ]},
          #|  "usingComponents": {"van-button": "@vant/weapp/button/index"}
          #|}
        ),
      ),
      ("app.js", "const config = require('./utils/config')\nApp({})"),
      ("app.wxss", "@import \"styles/base.wxss\";"),
      ("styles/base.wxss", ".a { color: red }"),
      ("images/home.png", "PNG"),
      ("utils/config.js", "module.exports = {}"),
      ("utils/format.wxs", "module.exports = { f: function (x) { return x } }"),
      (
        "pages/home/index.json", "{\"usingComponents\": {\"card\": \"/components/card/index\"}}",
      ),
      (
        "pages/home/index.js", "import { cfg } from '../../utils/config'\nPage({ go() { wx.navigateTo({ url: '/shop/list/index?id=1' }) } })",
      ),
      (
        "pages/home/index.wxml",
        (
          #|<import src="/templates/item.wxml" />
          #|<wxs src="../../utils/format.wxs" module="fmt" />
          #|<card title="{{ fmt.f(title) }}"></card>
          #|<template is="item" data="{{ item }}" />
          #|<van-button>ok</van-button>
          #|<navigator url="/pages/me/index" open-type="switchTab">me</navigator>
          #|<image src="/images/home.png" />
        ),
      ),
      (
        "templates/item.wxml", "<template name=\"item\"><text>{{ name }}</text></template>",
      ),
      ("components/card/index.json", component_json),
      ("components/card/index.js", component),
      ("components/card/index.wxml", "<view>card</view>"),
      ("pages/me/index.js", page),
      ("pages/me/index.wxml", "<view>me</view>"),
      (
        "shop/list/index.js", "const c = require('../../utils/config')\nPage({})",
      ),
      (
        "shop/list/index.wxml", "<navigator url=\"../../pages/home/index\" open-type=\"switchTab\" />",
      ),
      ("miniprogram_npm/@vant/weapp/button/index.json", component_json),
      ("miniprogram_npm/@vant/weapp/button/index.js", component),
      (
        "miniprogram_npm/@vant/weapp/button/index.wxml", "<button><slot /></button>",
      ),
      ("project.config.json", "{}"),
    ]),
  )
  assert_eq(found(report, include_info=true), [])
  assert_eq(report.packages.map(fn(p) { (p.name, p.files) }), [
    ("__APP__", 19),
    ("shop", 2),
  ])
}

///|
test "package boundaries: main, cross-subpackage and independent rules" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json",
        (
          #|{
          #|  "pages": ["pages/home/index"],
          #|  "subpackages": [
          #|    {"root": "pkgA", "pages": ["page/index"]},
          #|    {"root": "pkgB", "pages": ["page/index"]},
          #|    {"root": "solo", "pages": ["page/index"], "independent": true}
          #|  ]
          #|}
        ),
      ),
      ("app.js", "App({})"),
      ("utils/shared.js", "module.exports = 1"),
      (
        "pages/home/index.js", "require('../../pkgA/lib/chart')\nrequire.async('../../pkgB/lib/heavy')\nPage({})",
      ),
      ("pages/home/index.wxml", "<view />"),
      ("pkgA/lib/chart.js", "module.exports = 1"),
      ("pkgA/page/index.js", "require('../../pkgB/lib/heavy')\nPage({})"),
      (
        "pkgA/page/index.json",
        (
          #|{"usingComponents": {"b-widget": "/pkgB/widget/index", "b-lazy": "/pkgB/widget/index"},
          #| "componentPlaceholder": {"b-lazy": "view"}}
        ),
      ),
      ("pkgA/page/index.wxml", "<b-widget /><b-lazy />"),
      ("pkgB/lib/heavy.js", "module.exports = 1"),
      ("pkgB/page/index.js", "require('../../utils/shared')\nPage({})"),
      ("pkgB/page/index.wxml", "<view />"),
      ("pkgB/widget/index.json", component_json),
      ("pkgB/widget/index.js", component),
      ("pkgB/widget/index.wxml", "<view />"),
      ("solo/page/index.js", "require('../../utils/shared')\nPage({})"),
      ("solo/page/index.wxml", "<view />"),
    ]),
  )
  // Pages and components are visited before the files they own, so the
  // component reference is found first.
  assert_eq(found(report), [
    (
      "cross-subpackage-reference", "pkgA/page/index.json $.usingComponents[\"b-widget\"]",
    ),
    ("main-package-references-subpackage", "pages/home/index.js:1:9"),
    ("cross-subpackage-reference", "pkgA/page/index.js:1:9"),
    ("independent-subpackage-dependency", "solo/page/index.js:1:9"),
  ])
}

///|
test "navigation targets are checked against routes and the tab bar" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json",
        (
          #|{"pages": ["pages/home/index", "pages/detail/index", "pages/cart/index"],
          #| "tabBar": {"list": [{"pagePath": "pages/home/index"}, {"pagePath": "pages/cart/index"}]}}
        ),
      ),
      ("app.js", "App({})"),
      (
        "pages/home/index.js",
        (
          #|Page({
          #|  a() { wx.navigateTo({ url: '/pages/missing/index' }) },
          #|  b() { wx.switchTab({ url: '/pages/detail/index' }) },
          #|  c() { wx.navigateTo({ url: '/pages/cart/index?from=home' }) },
          #|  d() { wx.redirectTo({ url: '../detail/index' }) },
          #|  e() { wx.navigateTo({ url: 'detail/index' }) },
          #|  f() { wx.reLaunch({ url: '/pages/cart/index' }) },
          #|  g() { wx.navigateTo({ url: '/../../outside' }) },
          #|})
        ),
      ),
      (
        "pages/home/index.wxml",
        (
          #|<navigator url="/pages/cart/index">cart</navigator>
          #|<navigator url="/pages/detail/index" open-type="redirect" />
          #|<navigator url="/pages/x/index" target="miniProgram" />
          #|<navigator url="/pages/home/index" open-type="navigateBack" />
        ),
      ),
      ("pages/detail/index.js", page),
      ("pages/detail/index.wxml", "<view />"),
      ("pages/cart/index.js", page),
      ("pages/cart/index.wxml", "<view />"),
      ("utils/nav.js", "wx.navigateTo({ url: 'relative/is/unknown' })"),
    ]),
  )
  assert_eq(found(report), [
    ("unknown-navigation-target", "pages/home/index.js:2:30"),
    ("switch-tab-to-non-tab-page", "pages/home/index.js:3:29"),
    ("navigate-to-tab-page", "pages/home/index.js:4:30"),
    ("unknown-navigation-target", "pages/home/index.js:6:30"),
    ("invalid-navigation-target", "pages/home/index.js:8:30"),
    ("navigate-to-tab-page", "pages/home/index.wxml:1:1"),
  ])
}

///|
test "template scope follows import, not transitive imports" {
  let report = @routecheck.analyze(
    project([
      ("app.json", "{\"pages\": [\"pages/a/index\"]}"),
      ("app.js", "App({})"),
      ("pages/a/index.js", page),
      (
        "pages/a/index.wxml",
        (
          #|<import src="a.wxml" />
          #|<include src="part.wxml" />
          #|<template is="from-a" />
          #|<template is="from-b" />
          #|<template is="{{ dynamic }}" />
          #|<template name="local" />
          #|<template is="local" />
        ),
      ),
      (
        "pages/a/a.wxml", "<import src=\"b.wxml\" /><template name=\"from-a\" />",
      ),
      ("pages/a/b.wxml", "<template name=\"from-b\" />"),
      (
        "pages/a/part.wxml", "<template is=\"from-a\" /><template is=\"nowhere\" />",
      ),
    ]),
  )
  assert_eq(found(report), [
    ("unknown-template", "pages/a/index.wxml:4:1"),
    ("unknown-template", "pages/a/part.wxml:1:25"),
  ])
}

///|
test "unresolved references and broken components" {
  let report = @routecheck.analyze(
    project([
      ("app.json", "{\"pages\": [\"pages/a/index\"]}"),
      ("app.js", "require('./missing')"),
      (
        "pages/a/index.json", "{\"usingComponents\": {\"x\": \"../../comp/x\", \"y\": \"../../comp/y\", \"z\": \"../../comp/none\", \"p\": \"plugin://myPlugin/comp\"}}",
      ),
      ("pages/a/index.js", page),
      (
        "pages/a/index.wxml", "<x /><y /><z /><p /><image src=\"/img/none.png\" /><image src=\"{{ dyn }}\" /><include src=\"gone.wxml\" />",
      ),
      (
        "pages/a/index.wxss", "@import \"../../styles/nope.wxss\";\n.bg { background: url(/img/bg.png) }",
      ),
      ("comp/x.json", "{}"),
      ("comp/x.js", component),
      ("comp/x.wxml", "<view />"),
      ("comp/y.json", component_json),
      ("comp/y.wxml", "<wxs src=\"./f.wxs\" />"),
      ("comp/f.wxs", "var m = require('./m.js')"),
      ("comp/m.js", "module.exports = 1"),
    ]),
  )
  assert_eq(found(report), [
    ("unresolved-component", "pages/a/index.json $.usingComponents[\"z\"]"),
    ("unresolved-module", "app.js:1:9"),
    ("missing-asset", "pages/a/index.wxml:1:21"),
    ("unresolved-wxml-reference", "pages/a/index.wxml:1:75"),
    ("unresolved-style-import", "pages/a/index.wxss:1:1"),
    ("local-wxss-resource", "pages/a/index.wxss:2:19"),
    ("missing-component-flag", "comp/x.json $.component"),
    ("incomplete-component", "comp/y.json"),
    ("wxs-missing-module", "comp/y.wxml:1:1"),
    ("wxs-requires-non-wxs", "comp/f.wxs:1:17"),
  ])
}

///|
test "require cycles are reported once per strongly connected component" {
  let report = @routecheck.analyze(
    project([
      ("app.json", "{\"pages\": [\"pages/a/index\"]}"),
      ("app.js", "require('./lib/a')"),
      ("lib/a.js", "require('./b')"),
      ("lib/b.js", "require('./c')"),
      ("lib/c.js", "require('./a')\nrequire('./d')"),
      ("lib/d.js", "require('./d')"),
      ("pages/a/index.js", page),
      ("pages/a/index.wxml", "<view />"),
    ]),
  )
  let cycles = report.findings.filter(fn(f) { f.code == "require-cycle" })
  assert_eq(cycles.map(fn(f) { f.detail }), [
    "Modules require each other: lib/d.js. One side sees a partially initialized module.exports.",
    "Modules require each other: lib/a.js -> lib/b.js -> lib/c.js. One side sees a partially initialized module.exports.",
  ])
}

///|
test "unused components consider imported and included wxml and generics" {
  let report = @routecheck.analyze(
    project([
      ("app.json", "{\"pages\": [\"pages/a/index\"]}"),
      ("app.js", "App({})"),
      (
        "pages/a/index.json", "{\"usingComponents\": {\"used-direct\": \"/c/index\", \"used-in-include\": \"/c/index\", \"used-as-generic\": \"/c/index\", \"never\": \"/c/index\"}}",
      ),
      ("pages/a/index.js", page),
      (
        "pages/a/index.wxml", "<used-direct generic:item=\"used-as-generic\" /><include src=\"part.wxml\" />",
      ),
      ("pages/a/part.wxml", "<used-in-include />"),
      ("c/index.json", component_json),
      ("c/index.js", component),
      ("c/index.wxml", "<slot />"),
    ]),
  )
  assert_eq(found(report), [
    ("unused-component", "pages/a/index.json $.usingComponents[\"never\"]"),
  ])
}

///|
test "package sizes, budgets, unreferenced files and move suggestions" {
  let big = "x".repeat(300)
  let report = @routecheck.analyze(
    project([
      (
        "app.json", "{\"pages\": [\"pages/a/index\"], \"subpackages\": [{\"root\": \"sub\", \"name\": \"shop\", \"pages\": [\"p/index\"]}]}",
      ),
      ("app.js", "App({})"),
      ("pages/a/index.js", page),
      ("pages/a/index.wxml", "<view />"),
      ("utils/only-sub.js", big),
      ("utils/orphan.js", "module.exports = 0"),
      ("sub/p/index.js", "require('../../utils/only-sub')\nPage({})"),
      ("sub/p/index.wxml", "<view />"),
      ("README.md", "not packaged"),
    ]),
    options={ max_package_bytes: 256, max_total_bytes: 400, },
  )
  assert_eq(found(report, include_info=true), [
    ("unreferenced-file", "utils/orphan.js"),
    ("move-to-subpackage", "utils/only-sub.js"),
    ("package-size-exceeded", "app.json $.pages"),
    ("total-size-exceeded", "app.json $"),
  ])
  assert_eq(
    report.packages.map(fn(p) { (p.name, p.files, p.bytes, p.movable_bytes) }),
    [("__APP__", 6, 441, 0), ("shop", 2, 48, 300)],
  )
  let report = @routecheck.analyze(
    project([
      ("app.json", "{\"pages\": [\"pages/a/index\"]}"),
      ("app.js", big + big),
      ("pages/a/index.js", page),
      ("pages/a/index.wxml", "<view />"),
    ]),
    options={ max_package_bytes: 10000, max_total_bytes: 400, },
  )
  assert_eq(found(report), [("total-size-exceeded", "app.json $")])
}

///|
test "manifest problems stop graph analysis only when app.json is unusable" {
  let report = @routecheck.analyze(project([("app.json", "{")]))
  assert_eq(found(report), [("invalid-json", "app.json $")])
  let report = @routecheck.analyze(project([("pages/a.js", page)]))
  assert_eq(found(report), [("missing-app-json", "app.json")])
  let unreadable = @routecheck.Project::new([("app.json", 3)], fn(_) { None })
  assert_eq(found(@routecheck.analyze(unreadable)), [
    ("unreadable-file", "app.json"),
  ])
}

///|
test "custom tab bar and config files are entry points" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json", "{\"pages\": [\"pages/a/index\", \"pages/b/index\"], \"sitemapLocation\": \"sitemap.json\", \"themeLocation\": \"theme\", \"tabBar\": {\"custom\": true, \"list\": [{\"pagePath\": \"pages/a/index\"}, {\"pagePath\": \"pages/b/index\"}]}}",
      ),
      ("app.js", "App({})"),
      ("sitemap.json", "{}"),
      ("pages/a/index.js", page),
      ("pages/a/index.wxml", "<view />"),
      ("pages/b/index.js", page),
      ("pages/b/index.wxml", "<view />"),
    ]),
  )
  assert_eq(found(report), [
    ("missing-custom-tab-bar", "app.json $.tabBar.custom"),
    ("missing-config-file", "app.json $.themeLocation"),
  ])
}

///|
test "SARIF and DOT renderings" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json", "{\"pages\": [\"pages/a/index\"], \"subpackages\": [{\"root\": \"s\", \"pages\": [\"p\"]}]}",
      ),
      ("app.js", "require('./s/x')"),
      ("pages/a/index.js", page),
      ("pages/a/index.wxml", "<view />"),
      ("s/p.js", page),
      ("s/p.wxml", "<view />"),
      ("s/x.js", ""),
    ]),
  )
  let sarif = report.to_sarif()
  guard sarif is Object(top) &&
    top.get("runs") is Some(Array([Object(run)])) &&
    run.get("results") is Some(Array([Object(result)])) else {
    fail("unexpected SARIF shape")
  }
  assert_eq(
    result.get("ruleId"),
    Some(Json::string("main-package-references-subpackage")),
  )
  assert_eq(result.get("level"), Some(Json::string("error")))
  let dot = report.to_dot()
  assert_true(dot.contains("subgraph cluster_1"))
  assert_true(
    dot.contains("\"app.js\" -> \"s/x.js\" [label=\"require\", color=red"),
  )
  let text = report.to_text()
  assert_true(
    text.contains("error   app.js:1:9  [main-package-references-subpackage]"),
  )
  assert_true(text.contains("1 errors, 0 warnings, 0 notes."))
}

///|
test "TypeScript and Less sources are analyzed as their compiled files" {
  let sources = project([
    (
      "app.json", "{\"pages\": [\"pages/home/index\"], \"usingComponents\": {\"card\": \"/components/card/index\"}}",
    ),
    (
      "app.ts", "import { boot } from './utils/boot'\nApp({ onLaunch() { boot() } })",
    ),
    ("app.less", "// shared theme\n@import \"./styles/vars.less\";"),
    ("styles/vars.less", "@brand: red; // don't inline"),
    (
      "utils/boot.ts", "import { missing } from './gone'\nexport const boot = () => missing()",
    ),
    ("types/global.d.ts", "declare const x: number"),
    ("components/card/index.json", component_json),
    ("components/card/index.ts", "Component({})"),
    ("components/card/index.wxml", "<view />"),
    ("pages/home/index.json", "{}"),
    ("pages/home/index.ts", page),
    ("pages/home/index.wxml", "<card />"),
  ])
  let report = @routecheck.analyze(
    sources.with_compiler_plugins(["typescript", "less"]),
  )
  assert_eq(found(report), [("unresolved-module", "utils/boot.ts:1:25")])
  // Without the plugins the same sources are missing their compiled files.
  assert_true(
    found(@routecheck.analyze(sources)).contains(
      ("missing-page-file", "app.json $.pages[0]"),
    ),
  )
}

///|
test "extended libraries, inert links and camelCase openType are understood" {
  let report = @routecheck.analyze(
    project([
      (
        "app.json",
        (
          #|{
          #|  "pages": ["pages/home/index", "pages/me/index"],
          #|  "tabBar": {"list": [
          #|    {"pagePath": "pages/home/index"}, {"pagePath": "pages/me/index"}
          #|  ]},
          #|  "useExtendedLib": {"weui": "latest"}
          #|}
        ),
      ),
      ("app.js", "App({})"),
      (
        "pages/home/index.json", "{\"usingComponents\": {\"mp-cell\": \"weui-miniprogram/cell/cell\"}}",
      ),
      ("pages/home/index.js", page),
      (
        "pages/home/index.wxml",
        (
          #|<mp-cell />
          #|<navigator url="">placeholder</navigator>
          #|<navigator url="#top">anchor</navigator>
          #|<navigator url="javascript:;">noop</navigator>
          #|<navigator url="//beian.miit.gov.cn/">record</navigator>
          #|<navigator url="/pages/me/index" openType="switchTab">me</navigator>
        ),
      ),
      ("pages/me/index.js", page),
      ("pages/me/index.wxml", "<view />"),
    ]),
  )
  assert_eq(found(report), [])
}
