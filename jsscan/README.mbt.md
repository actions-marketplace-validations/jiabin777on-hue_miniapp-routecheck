# jiabin777on-hue/routecheck/jsscan

A JavaScript lexer for mini program scripts (regex vs. division, nested
template literals, escapes) and an extractor for the module references and
`wx.navigateTo`-style page navigations it can determine statically, plus
`requirePlugin` and `wx.createWorker` calls with literal arguments. In
TypeScript mode, imports used only as types are dropped as `tsc` drops them.

```mbt check
///|
test "extract dependencies and navigations" {
  let facts = @jsscan.analyze(
    (
      #|import type { Item } from './types'
      #|import { load } from '../../utils/api'
      #|const sku = require('/packageGoods/utils/sku.js')
      #|Page({ onLoad() { load() }, open(item: Item) { wx.navigateTo({ url: `/pages/detail/index?id=${item.id}` }) } })
    ),
    typescript=true,
  )
  assert_eq(facts.dependencies.map(fn(d) { d.specifier }), [
    "../../utils/api", "/packageGoods/utils/sku.js",
  ])
  assert_eq(facts.navigations.map(fn(n) { (n.api.name(), n.url) }), [
    ("wx.navigateTo", "/pages/detail/index"),
  ])
}
```
