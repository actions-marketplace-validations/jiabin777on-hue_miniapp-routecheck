///|
#derive(Eq, Debug)
pub(all) enum DependencyKind {
  /// `require('x')`
  Require
  /// `require.async('x')`, the asynchronous cross-package form.
  RequireAsync
  /// `import ... from 'x'`, `import 'x'` and `export ... from 'x'`
  Import
  /// `import('x')`
  DynamicImport
}

///|
#derive(Eq, Debug)
pub(all) struct Dependency {
  kind : DependencyKind
  specifier : String
  position : @scan.Position
}

///|
#derive(Eq, Debug)
pub(all) enum NavigationApi {
  NavigateTo
  RedirectTo
  ReLaunch
  SwitchTab
}

///|
pub fn NavigationApi::name(self : NavigationApi) -> String {
  match self {
    NavigateTo => "wx.navigateTo"
    RedirectTo => "wx.redirectTo"
    ReLaunch => "wx.reLaunch"
    SwitchTab => "wx.switchTab"
  }
}

///|
/// A navigation call whose target path is known statically. `url` holds the
/// page path without the query string.
#derive(Eq, Debug)
pub(all) struct Navigation {
  api : NavigationApi
  url : String
  position : @scan.Position
}

///|
#derive(Eq, Debug)
pub(all) struct ScriptFacts {
  dependencies : Array[Dependency]
  navigations : Array[Navigation]
  errors : Array[@scan.SyntaxError]
}

///|
fn token_kind(tokens : Array[Token], index : Int32) -> TokenKind? {
  if index >= 0 && index < tokens.length() {
    Some(tokens[index].kind)
  } else {
    None
  }
}

///|
fn is_punct(tokens : Array[Token], index : Int32, value : String) -> Bool {
  token_kind(tokens, index) is Some(Punct(p)) && p == value
}

///|
fn is_ident(tokens : Array[Token], index : Int32, value : String) -> Bool {
  token_kind(tokens, index) is Some(Ident(name)) && name == value
}

///|
/// A plain string or a template literal without substitutions.
fn static_string(tokens : Array[Token], index : Int32) -> String? {
  match token_kind(tokens, index) {
    Some(Str(value)) | Some(Template(value, false)) => Some(value)
    _ => None
  }
}

///|
/// Member access such as `obj.require` is not a module call.
fn is_member(tokens : Array[Token], index : Int32) -> Bool {
  is_punct(tokens, index - 1, ".") || is_punct(tokens, index - 1, "?.")
}

///|
/// Index of the token that closes the bracket at `open`, or the last token.
fn matching_close(tokens : Array[Token], open : Int32) -> Int32 {
  let mut depth = 0
  for index in open..<tokens.length() {
    match tokens[index].kind {
      Punct("(") | Punct("[") | Punct("{") => depth += 1
      Punct(")") | Punct("]") | Punct("}") => {
        depth -= 1
        if depth == 0 {
          return index
        }
      }
      _ => ()
    }
  }
  tokens.length() - 1
}

///|
/// The page path of a navigation `url` value. Returns None when the path
/// part depends on runtime values.
fn navigation_path(tokens : Array[Token], index : Int32) -> String? {
  let (text, complete) = match token_kind(tokens, index) {
    Some(Str(value)) => (value, true)
    Some(Template(value, has_substitution)) => (value, !has_substitution)
    _ => return None
  }
  match text.find("?") {
    Some(query) => Some(text[:query].to_owned())
    None if complete => Some(text)
    None => None
  }
}

///|
fn navigation_api(name : String) -> NavigationApi? {
  match name {
    "navigateTo" => Some(NavigateTo)
    "redirectTo" => Some(RedirectTo)
    "reLaunch" => Some(ReLaunch)
    "switchTab" => Some(SwitchTab)
    _ => None
  }
}

///|
/// Finds `url: <literal>` among the top-level properties of the object
/// literal that opens at `open`.
fn find_url_property(tokens : Array[Token], open : Int32) -> (String, Int32)? {
  let close = matching_close(tokens, open)
  let mut depth = 0
  for index in open..<close {
    match tokens[index].kind {
      Punct("(") | Punct("[") | Punct("{") => depth += 1
      Punct(")") | Punct("]") | Punct("}") => depth -= 1
      Ident("url") | Str("url") if depth == 1 &&
        is_punct(tokens, index + 1, ":") &&
        (is_punct(tokens, index - 1, "{") || is_punct(tokens, index - 1, ",")) =>
        return navigation_path(tokens, index + 2).map(fn(path) {
          (path, index + 2)
        })
      _ => ()
    }
  }
  None
}

///|
/// Collects the static module references and page navigations in a
/// JavaScript or WXS source file.
pub fn analyze(source : String) -> ScriptFacts {
  let (tokens, errors) = tokenize(source)
  let dependencies : Array[Dependency] = []
  let navigations : Array[Navigation] = []
  let add = fn(kind : DependencyKind, index : Int32) {
    guard static_string(tokens, index) is Some(specifier) else { return }
    // In call forms the literal must be the whole first argument.
    let call = kind != Import
    if call &&
      !(is_punct(tokens, index + 1, ")") || is_punct(tokens, index + 1, ",")) {
      return
    }
    dependencies.push({ kind, specifier, position: tokens[index].position, })
  }
  for index, token in tokens {
    guard token.kind is Ident(name) && !is_member(tokens, index) else {
      continue
    }
    match name {
      "require" if is_punct(tokens, index + 1, "(") => add(Require, index + 2)
      "require" if is_punct(tokens, index + 1, ".") &&
        is_ident(tokens, index + 2, "async") &&
        is_punct(tokens, index + 3, "(") => add(RequireAsync, index + 4)
      "import" if is_punct(tokens, index + 1, "(") =>
        add(DynamicImport, index + 2)
      "import" if static_string(tokens, index + 1) is Some(_) =>
        add(Import, index + 1)
      "import" if !is_punct(tokens, index + 1, ".") => {
        // import a, { b as c } from 'x'
        let mut cursor = index + 1
        while cursor < tokens.length() && !is_punct(tokens, cursor, ";") {
          if is_ident(tokens, cursor, "from") &&
            static_string(tokens, cursor + 1) is Some(_) {
            add(Import, cursor + 1)
            break
          }
          if is_punct(tokens, cursor, "{") {
            cursor = matching_close(tokens, cursor)
          } else if is_ident(tokens, cursor, "import") ||
            is_punct(tokens, cursor, "(") {
            break
          }
          cursor += 1
        }
      }
      "export" => {
        // export * from 'x' / export * as ns from 'x' / export { a } from 'x'
        let mut cursor = index + 1
        if is_punct(tokens, cursor, "{") {
          cursor = matching_close(tokens, cursor) + 1
        } else if is_punct(tokens, cursor, "*") {
          cursor += 1
          if is_ident(tokens, cursor, "as") {
            cursor += 2
          }
        } else {
          continue
        }
        if is_ident(tokens, cursor, "from") {
          add(Import, cursor + 1)
        }
      }
      "wx" if is_punct(tokens, index + 1, ".") &&
        is_punct(tokens, index + 3, "(") &&
        is_punct(tokens, index + 4, "{") =>
        if token_kind(tokens, index + 2) is Some(Ident(member_name)) &&
          navigation_api(member_name) is Some(api) &&
          find_url_property(tokens, index + 4) is Some((url, at)) {
          navigations.push({ api, url, position: tokens[at].position, })
        }
      _ => ()
    }
  }
  { dependencies, navigations, errors, }
}
