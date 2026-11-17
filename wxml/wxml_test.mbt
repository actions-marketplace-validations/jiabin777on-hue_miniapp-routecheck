///|
fn outline(document : @wxml.Document) -> Array[String] {
  let names = []
  document.each_element(fn(e) { names.push(e.name) })
  names
}

///|
fn messages(document : @wxml.Document) -> Array[(String, Int32)] {
  document.errors.map(fn(e) { (e.message, e.position.line) })
}

///|
test "element tree, attributes and document order" {
  let source =
    #|<import src="../tpl/card.wxml"/>
    #|<view class="page" hidden>
    #|  <template is="card" data="{{ item }}" />
    #|  <navigator url='/pages/detail/index?id=1' open-type=navigate>go</navigator>
    #|</view>
  let document = @wxml.parse(source)
  assert_true(document.errors.is_empty())
  assert_eq(outline(document), ["import", "view", "template", "navigator"])
  let view = document.roots[1]
  assert_eq(view.attribute("hidden").map(fn(a) { a.value }), Some(None))
  assert_eq(view.children[1].static_value("open-type"), Some("navigate"))
  assert_eq(view.children[0].static_value("data"), None)
  assert_eq(view.children[1].position, { line: 4, column: 3, })
}

///|
test "bindings may contain angle brackets, quotes and braces" {
  let source =
    #|<view wx:if="{{ a < b && c > d }}">{{ x > 1 ? '}}' : "<b>" }}</view>
    #|<text>{{ {a: 1}.a }}</text>
  let document = @wxml.parse(source)
  assert_true(document.errors.is_empty())
  assert_eq(outline(document), ["view", "text"])
  assert_eq(document.roots[0].static_value("wx:if"), None)
}

///|
test "inline wxs bodies are not parsed as markup" {
  let source =
    #|<wxs module="m">
    #|  var lt = function(a, b) { return a < b && "</view>" }
    #|  module.exports.lt = lt;
    #|</wxs>
    #|<wxs src="./fmt.wxs" module="fmt" />
    #|<view>{{ m.lt(1, 2) }}</view>
  let document = @wxml.parse(source)
  assert_true(document.errors.is_empty())
  assert_eq(outline(document), ["wxs", "wxs", "view"])
}

///|
test "unclosed and mismatched tags are reported and recovered" {
  let source =
    #|<view>
    #|  <text>hello
    #|</view>
    #|</button>
    #|<image src="a.png">
  let document = @wxml.parse(source)
  assert_eq(messages(document), [
    ("<text> is not closed before </view>.", 2),
    ("Closing tag </button> has no matching start tag.", 4),
    ("<image> is never closed.", 5),
  ])
  assert_eq(outline(document), ["view", "text", "image"])
}

///|
test "duplicate attributes, stray characters and unterminated constructs" {
  let source =
    #|<view class="a" class="b"></view>
    #|a < b
    #|<!-- never closed
  let document = @wxml.parse(source)
  assert_eq(messages(document), [
    ("Duplicate attribute 'class' on <view>.", 1),
    ("Unexpected '<' in text.", 2),
    ("Unterminated comment.", 3),
  ])
  let unterminated = @wxml.parse("<view class=\"{{ a \"></view>")
  assert_eq(messages(unterminated), [("Unterminated {{ }} binding.", 1)])
}

///|
test "byte order mark and CRLF line endings" {
  let document = @wxml.parse("\u{FEFF}<view>\r\n<text></text>\r\n</view>")
  assert_true(document.errors.is_empty())
  assert_eq(document.roots[0].children[0].position, { line: 2, column: 1, })
}
