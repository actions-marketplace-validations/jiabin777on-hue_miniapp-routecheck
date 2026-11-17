///|
/// A character cursor over source text that tracks 1-based line and column
/// numbers. The WXML, WXSS and JavaScript scanners share it so that every
/// diagnostic points at the same coordinates an editor shows.
pub struct Cursor {
  chars : Array[Char]
  mut pos : Int32
  mut line : Int32
  mut column : Int32
}

///|
pub fn Cursor::new(source : String) -> Cursor {
  let chars = source.to_array()
  // A UTF-8 byte order mark is not part of the source text.
  let start = if chars.length() > 0 && chars[0] == '\u{FEFF}' { 1 } else { 0 }
  { chars, pos: start, line: 1, column: 1, }
}

///|
pub fn Cursor::at_end(self : Cursor) -> Bool {
  self.pos >= self.chars.length()
}

///|
/// The character `offset` positions ahead, or `'\u{0}'` past the end.
pub fn Cursor::peek(self : Cursor, offset~ : Int32 = 0) -> Char {
  let index = self.pos + offset
  if index < self.chars.length() {
    self.chars[index]
  } else {
    '\u{0}'
  }
}

///|
pub fn Cursor::advance(self : Cursor) -> Char {
  guard self.pos < self.chars.length() else { return '\u{0}' }
  let c = self.chars[self.pos]
  self.pos += 1
  if c == '\n' {
    self.line += 1
    self.column = 1
  } else {
    self.column += 1
  }
  c
}

///|
pub fn Cursor::skip(self : Cursor, count : Int32) -> Unit {
  for _ in 0..<count {
    ignore(self.advance())
  }
}

///|
/// Whether the text at the cursor starts with `prefix`.
pub fn Cursor::looking_at(self : Cursor, prefix : String) -> Bool {
  let mut offset = 0
  for c in prefix {
    if self.peek(offset~) != c {
      return false
    }
    offset += 1
  }
  true
}

///|
/// Case-insensitive variant of `looking_at` for ASCII keywords such as
/// `@import`.
pub fn Cursor::looking_at_ascii_ci(self : Cursor, prefix : String) -> Bool {
  let mut offset = 0
  for c in prefix {
    if ascii_lower(self.peek(offset~)) != ascii_lower(c) {
      return false
    }
    offset += 1
  }
  true
}

///|
pub fn ascii_lower(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    (c.to_int() + 32).unsafe_to_char()
  } else {
    c
  }
}

///|
pub fn Cursor::skip_whitespace(self : Cursor) -> Unit {
  while !self.at_end() && self.peek().is_whitespace() {
    ignore(self.advance())
  }
}

///|
/// Text between two absolute character positions.
pub fn Cursor::slice(self : Cursor, start : Int32, end : Int32) -> String {
  String::from_array(self.chars[start:end])
}

///|
/// A source position.
#derive(Eq, Debug)
pub(all) struct Position {
  line : Int32
  column : Int32
}

///|
pub fn Cursor::position(self : Cursor) -> Position {
  { line: self.line, column: self.column, }
}

///|
/// A problem found while scanning, anchored at a source position.
#derive(Eq, Debug)
pub(all) struct SyntaxError {
  message : String
  position : Position
}
