///|
/// Lexical tokens of the ECMAScript subset the analyzer needs. Comments and
/// whitespace are dropped; strings are decoded; template literals keep their
/// leading static text so `url: \`/pages/a/index?id=${id}\`` can still be
/// checked.
#derive(Eq, Debug)
pub(all) enum TokenKind {
  Ident(String)
  Str(String)
  /// Static text before the first `${`, and whether a substitution follows.
  Template(String, Bool)
  Num
  Regex
  Punct(String)
}

///|
#derive(Eq, Debug)
pub(all) struct Token {
  kind : TokenKind
  position : @scan.Position
}

///|
let punctuators : Array[String] = [
  ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=", "=>",
  "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=",
  "%=", "&=", "|=", "^=", "**", "<<", ">>",
]

///|
/// Keywords after which a `/` starts a regular expression literal rather
/// than a division.
let regex_keywords : Array[String] = [
  "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
  "case", "do", "else", "yield", "await",
]

///|
fn is_ident_start(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c == '$' || c == '_' || c.to_int() > 127
}

///|
fn is_ident_part(c : Char) -> Bool {
  is_ident_start(c) || c.is_ascii_digit() || c == '\u{200C}' || c == '\u{200D}'
}

///|
fn is_line_break(c : Char) -> Bool {
  c == '\n' || c == '\r' || c == '\u{2028}' || c == '\u{2029}'
}

///|
priv struct Lexer {
  cursor : @scan.Cursor
  tokens : Array[Token]
  errors : Array[@scan.SyntaxError]
  /// Brace depth at which each open template substitution resumes.
  template_stack : Array[Int32]
  mut brace_depth : Int32
}

///|
fn Lexer::error(self : Lexer, message : String, at : @scan.Position) -> Unit {
  self.errors.push({ message, position: at, })
}

///|
fn Lexer::regex_allowed(self : Lexer) -> Bool {
  guard self.tokens.last() is Some(token) else { return true }
  match token.kind {
    Ident(name) => regex_keywords.contains(name)
    Punct(")") | Punct("]") | Punct("}") => false
    Punct(_) => true
    Template(_, true) => true
    Str(_) | Template(_, false) | Num | Regex => false
  }
}

///|
fn hex_value(c : Char) -> Int32? {
  match c {
    '0'..<='9' => Some(c.to_int() - '0'.to_int())
    'a'..<='f' => Some(c.to_int() - 'a'.to_int() + 10)
    'A'..<='F' => Some(c.to_int() - 'A'.to_int() + 10)
    _ => None
  }
}

///|
/// Reads `count` hex digits, or a braced code point when `count` is 0.
fn Lexer::read_hex_escape(self : Lexer, count : Int32) -> Char? {
  let cursor = self.cursor
  let mut value = 0
  if count == 0 {
    // \u{...}
    ignore(cursor.advance())
    let mut digits = 0
    while !cursor.at_end() && cursor.peek() != '}' {
      guard hex_value(cursor.advance()) is Some(digit) else { return None }
      value = value * 16 + digit
      digits += 1
      if value > 0x10FFFF {
        return None
      }
    }
    guard cursor.peek() == '}' && digits > 0 else { return None }
    ignore(cursor.advance())
  } else {
    for _ in 0..<count {
      guard hex_value(cursor.peek()) is Some(digit) else { return None }
      ignore(cursor.advance())
      value = value * 16 + digit
    }
  }
  Some(value.unsafe_to_char())
}

///|
/// Decodes the escape sequence after a backslash into `out`.
fn Lexer::read_escape(self : Lexer, out : StringBuilder) -> Unit {
  let cursor = self.cursor
  let at = cursor.position()
  let c = cursor.advance()
  match c {
    'n' => out.write_char('\n')
    't' => out.write_char('\t')
    'r' => out.write_char('\r')
    'b' => out.write_char('\u{8}')
    'f' => out.write_char('\u{C}')
    'v' => out.write_char('\u{B}')
    '0' if !cursor.peek().is_ascii_digit() => out.write_char('\u{0}')
    'x' =>
      match self.read_hex_escape(2) {
        Some(decoded) => out.write_char(decoded)
        None => self.error("Invalid hexadecimal escape sequence.", at)
      }
    'u' => {
      let decoded = if cursor.peek() == '{' {
        self.read_hex_escape(0)
      } else {
        self.read_hex_escape(4)
      }
      match decoded {
        Some(decoded) => out.write_char(decoded)
        None => self.error("Invalid unicode escape sequence.", at)
      }
    }
    '\r' => if cursor.peek() == '\n' { ignore(cursor.advance()) }
    '\n' | '\u{2028}' | '\u{2029}' => ()
    _ => out.write_char(c)
  }
}

///|
fn Lexer::read_string(self : Lexer, quote : Char) -> Unit {
  let cursor = self.cursor
  let start = cursor.position()
  ignore(cursor.advance())
  let out = StringBuilder()
  while true {
    if cursor.at_end() || is_line_break(cursor.peek()) {
      self.error("Unterminated string literal.", start)
      break
    }
    let c = cursor.advance()
    if c == quote {
      break
    } else if c == '\\' {
      self.read_escape(out)
    } else {
      out.write_char(c)
    }
  }
  self.tokens.push({ kind: Str(out.to_string()), position: start, })
}

///|
priv enum ChunkEnd {
  Closed
  Substitution
  Unterminated
}

///|
/// Scans template text up to the closing backtick or the next `${`.
fn Lexer::read_template_chunk(self : Lexer, out : StringBuilder) -> ChunkEnd {
  let cursor = self.cursor
  while !cursor.at_end() {
    let c = cursor.peek()
    if c == '`' {
      ignore(cursor.advance())
      return Closed
    }
    if c == '$' && cursor.peek(offset=1) == '{' {
      cursor.skip(2)
      return Substitution
    }
    ignore(cursor.advance())
    if c == '\\' {
      self.read_escape(out)
    } else {
      out.write_char(c)
    }
  }
  Unterminated
}

///|
fn Lexer::read_template(self : Lexer) -> Unit {
  let start = self.cursor.position()
  ignore(self.cursor.advance())
  let out = StringBuilder()
  let substitution = match self.read_template_chunk(out) {
    Closed => false
    Substitution => {
      self.template_stack.push(self.brace_depth)
      true
    }
    Unterminated => {
      self.error("Unterminated template literal.", start)
      false
    }
  }
  self.tokens.push({
    kind: Template(out.to_string(), substitution),
    position: start,
  })
}

///|
/// Continues a template literal after the `}` that closes a substitution.
/// Later chunks are not needed for path checks, so they are consumed
/// without producing tokens.
fn Lexer::resume_template(self : Lexer) -> Unit {
  let start = self.cursor.position()
  match self.read_template_chunk(StringBuilder()) {
    Closed => ()
    Substitution => self.template_stack.push(self.brace_depth)
    Unterminated => self.error("Unterminated template literal.", start)
  }
}

///|
fn Lexer::read_regex(self : Lexer) -> Unit {
  let cursor = self.cursor
  let start = cursor.position()
  ignore(cursor.advance())
  let mut in_class = false
  while true {
    if cursor.at_end() || is_line_break(cursor.peek()) {
      self.error("Unterminated regular expression literal.", start)
      break
    }
    let c = cursor.advance()
    if c == '\\' {
      ignore(cursor.advance())
    } else if c == '[' {
      in_class = true
    } else if c == ']' {
      in_class = false
    } else if c == '/' && !in_class {
      break
    }
  }
  while is_ident_part(cursor.peek()) {
    ignore(cursor.advance())
  }
  self.tokens.push({ kind: Regex, position: start, })
}

///|
fn Lexer::read_number(self : Lexer) -> Unit {
  let cursor = self.cursor
  let start = cursor.position()
  while !cursor.at_end() {
    let c = cursor.peek()
    if (c == 'e' || c == 'E') &&
      (cursor.peek(offset=1) == '+' || cursor.peek(offset=1) == '-') {
      cursor.skip(2)
    } else if is_ident_part(c) || c == '.' {
      ignore(cursor.advance())
    } else {
      break
    }
  }
  self.tokens.push({ kind: Num, position: start, })
}

///|
fn Lexer::skip_comment(self : Lexer) -> Bool {
  let cursor = self.cursor
  if cursor.looking_at("//") {
    while !cursor.at_end() && !is_line_break(cursor.peek()) {
      ignore(cursor.advance())
    }
    return true
  }
  if cursor.looking_at("/*") {
    let start = cursor.position()
    cursor.skip(2)
    while !cursor.at_end() && !cursor.looking_at("*/") {
      ignore(cursor.advance())
    }
    if cursor.at_end() {
      self.error("Unterminated block comment.", start)
    } else {
      cursor.skip(2)
    }
    return true
  }
  false
}

///|
fn Lexer::read_punctuator(self : Lexer) -> Unit {
  let cursor = self.cursor
  let start = cursor.position()
  for candidate in punctuators {
    if cursor.looking_at(candidate) {
      cursor.skip(candidate.length())
      self.tokens.push({ kind: Punct(candidate), position: start, })
      return
    }
  }
  let c = cursor.advance()
  self.tokens.push({ kind: Punct(c.to_string()), position: start, })
}

///|
/// Splits JavaScript source into tokens. Lexing never stops at the first
/// error: problems are collected and scanning resumes, so one bad literal
/// does not hide the dependencies after it.
pub fn tokenize(source : String) -> (Array[Token], Array[@scan.SyntaxError]) {
  let lexer : Lexer = {
    cursor: @scan.Cursor::new(source),
    tokens: [],
    errors: [],
    template_stack: [],
    brace_depth: 0,
  }
  let cursor = lexer.cursor
  // A leading hashbang line is ignored by JavaScript engines.
  if cursor.looking_at("#!") {
    while !cursor.at_end() && !is_line_break(cursor.peek()) {
      ignore(cursor.advance())
    }
  }
  while !cursor.at_end() {
    let c = cursor.peek()
    if c.is_whitespace() || is_line_break(c) || c == '\u{FEFF}' {
      ignore(cursor.advance())
    } else if c == '/' && lexer.skip_comment() {
      ()
    } else if c == '/' && lexer.regex_allowed() {
      lexer.read_regex()
    } else if c == '"' || c == '\'' {
      lexer.read_string(c)
    } else if c == '`' {
      lexer.read_template()
    } else if c.is_ascii_digit() ||
      (c == '.' && cursor.peek(offset=1).is_ascii_digit()) {
      lexer.read_number()
    } else if is_ident_start(c) || c == '\\' {
      let start = cursor.position()
      let out = StringBuilder()
      while !cursor.at_end() &&
            (is_ident_part(cursor.peek()) || cursor.peek() == '\\') {
        let part = cursor.advance()
        if part == '\\' {
          lexer.read_escape(out)
        } else {
          out.write_char(part)
        }
      }
      lexer.tokens.push({ kind: Ident(out.to_string()), position: start, })
    } else if c == '{' {
      lexer.brace_depth += 1
      lexer.read_punctuator()
    } else if c == '}' {
      match lexer.template_stack.last() {
        Some(depth) if depth == lexer.brace_depth => {
          ignore(lexer.template_stack.pop())
          ignore(cursor.advance())
          lexer.resume_template()
        }
        _ => {
          lexer.brace_depth -= 1
          lexer.read_punctuator()
        }
      }
    } else {
      lexer.read_punctuator()
    }
  }
  if !lexer.template_stack.is_empty() {
    lexer.error("Unterminated template literal.", cursor.position())
  }
  (lexer.tokens, lexer.errors)
}
