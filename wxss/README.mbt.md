# jiabin777on-hue/routecheck/wxss

Finds `@import` targets and `url()` references in WXSS, skipping comments
and strings so commented-out imports are not reported. `line_comments`
also skips `//` comments in Less and Sass sources.

```mbt check
///|
test "collect style references" {
  let facts = @wxss.analyze(
    (
      #|/* @import "old.wxss"; */
      #|@import "/styles/base.wxss";
      #|.logo { background: url(/images/logo.png); }
    ),
  )
  assert_eq(facts.references.map(fn(r) { r.target }), [
    "/styles/base.wxss", "/images/logo.png",
  ])
}
```
