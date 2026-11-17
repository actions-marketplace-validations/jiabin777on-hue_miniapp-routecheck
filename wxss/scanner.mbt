///|
#derive(Eq, Debug)
pub(all) enum ReferenceKind {
  /// `@import "x.wxss";`
  Import
  /// `url(x)` inside a declaration, such as a background image.
  Url
}

///|
#derive(Eq, Debug)
pub(all) struct Reference {
  kind : ReferenceKind
  target : String
  position : @scan.Position
}

///|
#derive(Eq, Debug)
pub(all) struct StyleFacts {
  references : Array[Reference]
  errors : Array[@scan.SyntaxError]
}

///|
priv struct Scanner {
  cursor : @scan.Cursor
  references : Array[Reference]
  errors : Array[@scan.SyntaxError]
}

///|
fn Scanner::read_string(self : Scanner) -> String? {
  let cursor = self.cursor
  let start = cursor.position()
  let quote = cursor.advance()
  let out = StringBuilder()
  while true {
    if cursor.at_end() || cursor.peek() == '\n' {
      self.errors.push({ message: "Unterminated string.", position: start, })
      return None
    }
    let c = cursor.advance()
    if c == quote {
      break
    }
    if c == '\\' {
      let escaped = cursor.advance()
      if escaped != '\n' {
        out.write_char(escaped)
      }
    } else {
      out.write_char(c)
    }
  }
  Some(out.to_string())
}

///|
/// Reads the argument of `url(` after the opening parenthesis.
fn Scanner::read_url(self : Scanner) -> String? {
  let cursor = self.cursor
  let start = cursor.position()
  cursor.skip_whitespace()
  let value = if cursor.peek() == '"' || cursor.peek() == '\'' {
    self.read_string()
  } else {
    let out = StringBuilder()
    while !cursor.at_end() && cursor.peek() != ')' && cursor.peek() != '\n' {
      out.write_char(cursor.advance())
    }
    Some(out.to_string().trim().to_owned())
  }
  cursor.skip_whitespace()
  if cursor.peek() != ')' {
    self.errors.push({ message: "Unterminated url().", position: start, })
    return None
  }
  ignore(cursor.advance())
  value
}

///|
fn Scanner::read_import(self : Scanner) -> Unit {
  let cursor = self.cursor
  let start = cursor.position()
  cursor.skip(7)
  cursor.skip_whitespace()
  let target = if cursor.peek() == '"' || cursor.peek() == '\'' {
    self.read_string()
  } else if cursor.looking_at_ascii_ci("url(") {
    cursor.skip(4)
    self.read_url()
  } else {
    self.errors.push({
      message: "Expected a quoted path after @import.",
      position: start,
    })
    None
  }
  if target is Some(target) {
    self.references.push({ kind: Import, target, position: start, })
  }
}

///|
/// Collects `@import` targets and `url()` references from WXSS source.
/// Comments and string contents are skipped so commented-out imports are not
/// reported.
pub fn analyze(source : String) -> StyleFacts {
  let scanner : Scanner = {
    cursor: @scan.Cursor::new(source),
    references: [],
    errors: [],
  }
  let cursor = scanner.cursor
  while !cursor.at_end() {
    if cursor.looking_at("/*") {
      let start = cursor.position()
      cursor.skip(2)
      while !cursor.at_end() && !cursor.looking_at("*/") {
        ignore(cursor.advance())
      }
      if cursor.at_end() {
        scanner.errors.push({
          message: "Unterminated comment.",
          position: start,
        })
      } else {
        cursor.skip(2)
      }
    } else if cursor.peek() == '"' || cursor.peek() == '\'' {
      ignore(scanner.read_string())
    } else if cursor.looking_at_ascii_ci("@import") &&
      !is_name_char(cursor.peek(offset=7)) {
      scanner.read_import()
    } else if cursor.looking_at_ascii_ci("url(") &&
      (cursor.pos == 0 || !is_name_char(cursor.chars[cursor.pos - 1])) {
      let start = cursor.position()
      cursor.skip(4)
      if scanner.read_url() is Some(target) {
        scanner.references.push({ kind: Url, target, position: start, })
      }
    } else {
      ignore(cursor.advance())
    }
  }
  { references: scanner.references, errors: scanner.errors, }
}

///|
fn is_name_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '-' || c == '_'
}
