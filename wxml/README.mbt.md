# jiabin777on-hue/routecheck/wxml

A WXML parser with error recovery: it builds the element tree, reports
unclosed and mismatched tags, understands `{{ }}` bindings and skips the
body of `<wxs>` blocks.

```mbt check
///|
test "parse a WXML template" {
  let doc = @wxml.parse(
    "<view wx:for=\"{{items}}\"><navigator url=\"/pages/a/index?id=1\">go</navigator></view>",
  )
  let urls = []
  doc.each_element(fn(e) {
    if e.static_value("url") is Some(url) {
      urls.push(url)
    }
  })
  assert_eq(urls, ["/pages/a/index?id=1"])
  assert_eq(doc.errors.length(), 0)
}
```
