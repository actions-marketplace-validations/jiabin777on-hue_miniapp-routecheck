///|
fn specifiers(source : String) -> Array[(@jsscan.DependencyKind, String)] {
  @jsscan.analyze(source).dependencies.map(fn(d) { (d.kind, d.specifier) })
}

///|
fn routes(source : String) -> Array[(String, String)] {
  @jsscan.analyze(source).navigations.map(fn(n) { (n.api.name(), n.url) })
}

///|
test "module references in CommonJS, ES modules and re-exports" {
  let source =
    #|const a = require('./a')
    #|const { b } = require("../lib/b.js")
    #|import c from './c'
    #|import d, { e as f } from "/utils/d"
    #|import './side-effect'
    #|export * from './star'
    #|export * as ns from './ns'
    #|export { g } from './g'
    #|const lazy = () => import('./lazy')
    #|require.async('../sub/heavy').then(m => m)
  assert_eq(specifiers(source), [
    (Require, "./a"),
    (Require, "../lib/b.js"),
    (Import, "./c"),
    (Import, "/utils/d"),
    (Import, "./side-effect"),
    (Import, "./star"),
    (Import, "./ns"),
    (Import, "./g"),
    (DynamicImport, "./lazy"),
    (RequireAsync, "../sub/heavy"),
  ])
}

///|
test "comments, strings, regexes and member calls hide fake requires" {
  let source =
    #|// require('./line-comment')
    #|/* require('./block-comment') */
    #|const s = "require('./in-string')"
    #|const t = `require('./in-template')`
    #|const r = /require\('.\/in-regex'\)/g
    #|loader.require('./member-call')
    #|const ratio = total / count / 2 // division, not a regex
    #|const real = require('./real')
  assert_eq(specifiers(source), [(Require, "./real")])
}

///|
test "regex after keyword and template substitutions with nested braces" {
  let source =
    #|function f(x) { return /[/]}/.test(x) }
    #|const msg = `a ${ { k: `inner ${1}` }.k } b`
    #|const real = require('./after-template')
  let facts = @jsscan.analyze(source)
  assert_true(facts.errors.is_empty())
  assert_eq(specifiers(source), [(Require, "./after-template")])
}

///|
test "escape sequences are decoded in specifiers" {
  assert_eq(specifiers("require('\\u002e/a\\x2fb')"), [(Require, "./a/b")])
  assert_eq(specifiers("require('./\\u{6587}')"), [(Require, "./文")])
}

///|
test "dynamic specifiers are skipped" {
  assert_eq(specifiers("require(name); require('./' + x); import(`./${y}`)"), [])
}

///|
test "static navigation targets" {
  let source =
    #|wx.navigateTo({ url: '/pages/detail/index?id=1' })
    #|wx.redirectTo({ success() {}, url: "../list/index" })
    #|wx.switchTab({ url: `/pages/home/index` })
    #|wx.reLaunch({ url: `/pages/order/index?id=${id}&from=share` })
    #|wx.navigateTo({ url: `/pages/${name}/index` })
    #|wx.navigateTo({ url })
    #|wx.navigateTo({ data: { url: '/nested/is/ignored' }, fail() {} })
    #|other.wx.navigateTo({ url: '/pages/member/index' })
  assert_eq(routes(source), [
    ("wx.navigateTo", "/pages/detail/index"),
    ("wx.redirectTo", "../list/index"),
    ("wx.switchTab", "/pages/home/index"),
    ("wx.reLaunch", "/pages/order/index"),
  ])
}

///|
test "positions are 1-based line and column" {
  let facts = @jsscan.analyze("\n  const x = require('./x')")
  assert_eq(facts.dependencies[0].position, { line: 2, column: 21, })
}

///|
test "lexical errors are reported and scanning continues" {
  let facts = @jsscan.analyze(
    "const s = 'open\nconst t = require('./still-found')\n/* never closed",
  )
  assert_eq(facts.errors.map(fn(e) { (e.message, e.position.line) }), [
    ("Unterminated string literal.", 1),
    ("Unterminated block comment.", 3),
  ])
  assert_eq(facts.dependencies.map(fn(d) { d.specifier }), ["./still-found"])
}

///|
test "unterminated template and bad escapes" {
  let (_, errors) = @jsscan.tokenize("`abc ${x")
  assert_eq(errors.length(), 1)
  let (_, errors) = @jsscan.tokenize("'\\xZZ'")
  assert_eq(errors[0].message, "Invalid hexadecimal escape sequence.")
}

///|
fn ts_specifiers(source : String) -> Array[String] {
  @jsscan.analyze(source, typescript=true).dependencies.map(fn(d) {
    d.specifier
  })
}

///|
test "TypeScript imports used only as types are dropped like tsc drops them" {
  let source =
    #|import type { Options } from './types'
    #|import XrFrame from 'XrFrame'
    #|import { type Shape, make } from './shape'
    #|import { type Only } from './only-types'
    #|import Base from './base'
    #|import * as fmt from './format'
    #|import './side-effect'
    #|const schema: XrFrame.IComponentSchema = {}
    #|let list: Array<Shape> = []
    #|class A extends Base implements XrFrame.Component {}
    #|const s = make() as Shape
    #|export const f = (x: Options) => fmt.pad(x)
  assert_eq(ts_specifiers(source), [
    "./shape", "./base", "./format", "./side-effect",
  ])
  // Plain JavaScript keeps every import.
  assert_eq(specifiers(source).length(), 7)
}
