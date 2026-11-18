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
/// Mini program APIs whose first argument names a plugin or a file.
#derive(Eq, Debug)
pub(all) enum CallApi {
  /// `requirePlugin('alias')`; the argument is a plugin alias or AppID.
  RequirePlugin
  /// `wx.createWorker('workers/x/index.js')`; the argument is the entry
  /// file, relative to the mini program root.
  CreateWorker
}

///|
pub fn CallApi::name(self : CallApi) -> String {
  match self {
    RequirePlugin => "requirePlugin"
    CreateWorker => "wx.createWorker"
  }
}

///|
/// A call to a `CallApi` whose first argument is a string literal.
#derive(Eq, Debug)
pub(all) struct ApiCall {
  api : CallApi
  argument : String
  position : @scan.Position
}

///|
#derive(Eq, Debug)
pub(all) struct ScriptFacts {
  dependencies : Array[Dependency]
  navigations : Array[Navigation]
  calls : Array[ApiCall]
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
/// The local names an import declaration binds, given the tokens between
/// `import` and `from`: `a`, `* as ns`, `{ b, c as d }`. Specifiers marked
/// `type` (`{ type T }`) bind no runtime value and are left out.
fn import_bindings(
  tokens : Array[Token],
  start : Int32,
  end : Int32,
) -> Array[String] {
  let names = []
  let mut index = start
  let mut in_braces = false
  while index < end {
    match tokens[index].kind {
      Punct("{") => in_braces = true
      Punct("}") => in_braces = false
      Ident("type") if in_braces &&
        token_kind(tokens, index + 1) is Some(Ident(_)) => {
        // Skip `type T` or `type T as U`.
        index += 2
        if is_ident(tokens, index, "as") {
          index += 2
        }
        continue
      }
      Ident(name) if name != "as" => {
        if is_ident(tokens, index + 1, "as") {
          // `b as c` binds c.
          index += 2
          continue
        }
        names.push(name)
      }
      _ => ()
    }
    index += 1
  }
  names
}

///|
/// Tokens after which an identifier is read as a type, not a value:
/// annotations (`x: T`), type arguments (`Array<T>`), unions, intersections,
/// assertions and `implements` clauses.
fn in_type_position(tokens : Array[Token], index : Int32) -> Bool {
  match token_kind(tokens, index - 1) {
    Some(Punct(":")) | Some(Punct("<")) | Some(Punct("|")) | Some(Punct("&")) =>
      true
    Some(Ident("as")) | Some(Ident("implements")) | Some(Ident("satisfies")) =>
      true
    _ => false
  }
}

///|
/// Whether TypeScript removes the import declaration spanning `start` to
/// `end`: it binds names, and every use of them outside the declaration is
/// in a type position. This mirrors how `tsc` elides imports that are only
/// used as types; it is lexical, so a value used as an object property
/// value (`{ key: Name }`) is mistaken for a type.
fn elided_import(tokens : Array[Token], start : Int32, end : Int32) -> Bool {
  let names = import_bindings(tokens, start, end)
  if names.is_empty() {
    // `import {} from 'x'` and `import { type T } from 'x'` bind nothing
    // at runtime, and tsc removes them too.
    return true
  }
  for index, token in tokens {
    if index >= start && index < end {
      continue
    }
    if token.kind is Ident(name) &&
      names.contains(name) &&
      !is_member(tokens, index) &&
      !in_type_position(tokens, index) {
      return false
    }
  }
  true
}

///|
/// Collects the static module references, page navigations and
/// `requirePlugin` / `wx.createWorker` calls in a
/// JavaScript or WXS source file. With `typescript`, the source is a
/// DevTools-compiled `.ts` file: `import type` and imports whose bindings
/// are only used as types are dropped, as the compiler drops them.
pub fn analyze(source : String, typescript~ : Bool = false) -> ScriptFacts {
  let (tokens, errors) = tokenize(source)
  let dependencies : Array[Dependency] = []
  let navigations : Array[Navigation] = []
  let calls : Array[ApiCall] = []
  // The literal must be the whole first argument.
  let first_argument = fn(index : Int32) -> String? {
    guard static_string(tokens, index) is Some(value) &&
      (is_punct(tokens, index + 1, ")") || is_punct(tokens, index + 1, ",")) else {
      return None
    }
    Some(value)
  }
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
        if typescript &&
          is_ident(tokens, index + 1, "type") &&
          !is_ident(tokens, index + 2, "from") {
          continue
        }
        let mut cursor = index + 1
        while cursor < tokens.length() && !is_punct(tokens, cursor, ";") {
          if is_ident(tokens, cursor, "from") &&
            static_string(tokens, cursor + 1) is Some(_) {
            if !(typescript && elided_import(tokens, index + 1, cursor)) {
              add(Import, cursor + 1)
            }
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
      "requirePlugin" if is_punct(tokens, index + 1, "(") =>
        if first_argument(index + 2) is Some(argument) {
          calls.push({
            api: RequirePlugin,
            argument,
            position: tokens[index + 2].position,
          })
        }
      "wx" if is_punct(tokens, index + 1, ".") &&
        is_ident(tokens, index + 2, "createWorker") &&
        is_punct(tokens, index + 3, "(") =>
        if first_argument(index + 4) is Some(argument) {
          calls.push({
            api: CreateWorker,
            argument,
            position: tokens[index + 4].position,
          })
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
  { dependencies, navigations, calls, errors, }
}
