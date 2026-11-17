///|
fn refs(source : String) -> Array[(@wxss.ReferenceKind, String)] {
  @wxss.analyze(source).references.map(fn(r) { (r.kind, r.target) })
}

///|
test "imports in every accepted form" {
  let source =
    #|@import "common.wxss";
    #|@import './theme/dark.wxss';
    #|@IMPORT url("/styles/base.wxss");
    #|@import url(reset.wxss);
  assert_eq(refs(source), [
    (Import, "common.wxss"),
    (Import, "./theme/dark.wxss"),
    (Import, "/styles/base.wxss"),
    (Import, "reset.wxss"),
  ])
}

///|
test "comments and strings hide imports, url() values are collected" {
  let source =
    #|/* @import "commented.wxss"; */
    #|.a::before { content: "@import 'in-string.wxss'"; }
    #|.b { background-image: url( ./bg.png ); }
    #|.c { background: url('https://cdn.example.com/x.png') no-repeat; }
    #|.d { --my-url(: 1; }
  assert_eq(refs(source), [
    (Url, "./bg.png"),
    (Url, "https://cdn.example.com/x.png"),
  ])
}

///|
test "malformed input reports positions" {
  let facts = @wxss.analyze("@import ;\n.a { b: \"open\n}\n/* end")
  assert_eq(facts.errors.map(fn(e) { (e.message, e.position.line) }), [
    ("Expected a quoted path after @import.", 1),
    ("Unterminated string.", 2),
    ("Unterminated comment.", 4),
  ])
}
