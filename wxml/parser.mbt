///|
#derive(Eq, Debug)
pub(all) struct Attribute {
  name : String
  /// None for a bare attribute such as `<input disabled />`.
  value : String?
  position : @scan.Position
}

///|
#derive(Eq, Debug)
pub(all) struct Element {
  name : String
  attributes : Array[Attribute]
  children : Array[Element]
  position : @scan.Position
}

///|
pub fn Element::attribute(self : Element, name : String) -> Attribute? {
  for attribute in self.attributes {
    if attribute.name == name {
      return Some(attribute)
    }
  }
  None
}

///|
/// The attribute value when it is present and contains no `{{ }}` binding.
pub fn Element::static_value(self : Element, name : String) -> String? {
  match self.attribute(name) {
    Some({ value: Some(value), .. }) if !value.contains("{{") => Some(value)
    _ => None
  }
}

///|
#derive(Eq, Debug)
pub(all) struct Document {
  roots : Array[Element]
  errors : Array[@scan.SyntaxError]
}

///|
/// Depth-first, document-order traversal.
pub fn Document::each_element(self : Document, f : (Element) -> Unit) -> Unit {
  fn visit(element : Element) {
    f(element)
    for child in element.children {
      visit(child)
    }
  }

  for root in self.roots {
    visit(root)
  }
}

///|
/// Elements whose body is script text rather than markup.
let raw_text_elements : Array[String] = ["wxs"]

///|
priv struct Open {
  name : String
  attributes : Array[Attribute]
  children : Array[Element]
  position : @scan.Position
}

///|
priv struct Parser {
  cursor : @scan.Cursor
  stack : Array[Open]
  roots : Array[Element]
  errors : Array[@scan.SyntaxError]
}

///|
fn Parser::error(self : Parser, message : String, at : @scan.Position) -> Unit {
  self.errors.push({ message, position: at, })
}

///|
fn is_name_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() ||
  c.is_ascii_digit() ||
  c == '-' ||
  c == '_' ||
  c == ':' ||
  c == '.'
}

///|
fn is_attribute_name_char(c : Char) -> Bool {
  !(c.is_whitespace() ||
  c == '=' ||
  c == '>' ||
  c == '/' ||
  c == '"' ||
  c == '\'' ||
  c == '<' ||
  c == '\u{0}')
}

///|
/// Skips a `{{ ... }}` binding, honouring string literals inside it so that
/// `{{ a > b ? '}}' : c }}` is a single binding. `stop` ends the binding
/// early, which keeps an unbalanced binding from swallowing the closing
/// quote of an attribute.
fn Parser::skip_binding(
  self : Parser,
  out : StringBuilder,
  stop~ : Char = '\u{0}',
) -> Unit {
  let cursor = self.cursor
  let start = cursor.position()
  out.write_string("{{")
  cursor.skip(2)
  let mut quote = '\u{0}'
  while !cursor.at_end() {
    let c = cursor.peek()
    if quote != '\u{0}' {
      if c == stop {
        break
      }
      out.write_char(cursor.advance())
      if c == '\\' {
        out.write_char(cursor.advance())
      } else if c == quote {
        quote = '\u{0}'
      }
    } else if cursor.looking_at("}}") {
      out.write_string("}}")
      cursor.skip(2)
      return
    } else if c == stop {
      break
    } else {
      if c == '"' || c == '\'' || c == '`' {
        quote = c
      }
      out.write_char(cursor.advance())
    }
  }
  self.error("Unterminated {{ }} binding.", start)
}

///|
fn Parser::read_name(self : Parser, accept : (Char) -> Bool) -> String {
  let cursor = self.cursor
  let start = cursor.pos
  while !cursor.at_end() && accept(cursor.peek()) {
    ignore(cursor.advance())
  }
  cursor.slice(start, cursor.pos)
}

///|
fn Parser::read_attribute_value(self : Parser) -> String {
  let cursor = self.cursor
  let out = StringBuilder()
  let c = cursor.peek()
  if c == '"' || c == '\'' {
    let start = cursor.position()
    ignore(cursor.advance())
    while true {
      if cursor.at_end() {
        self.error("Unterminated attribute value.", start)
        break
      }
      if cursor.peek() == c {
        ignore(cursor.advance())
        break
      }
      if cursor.looking_at("{{") {
        self.skip_binding(out, stop=c)
      } else {
        out.write_char(cursor.advance())
      }
    }
  } else {
    while !cursor.at_end() &&
          !cursor.peek().is_whitespace() &&
          cursor.peek() != '>' &&
          !cursor.looking_at("/>") {
      if cursor.looking_at("{{") {
        self.skip_binding(out)
      } else {
        out.write_char(cursor.advance())
      }
    }
  }
  out.to_string()
}

///|
fn Parser::attach(self : Parser, element : Element) -> Unit {
  match self.stack.last() {
    Some(parent) => parent.children.push(element)
    None => self.roots.push(element)
  }
}

///|
fn Parser::close_top(self : Parser) -> Unit {
  guard self.stack.pop() is Some(open) else { return }
  self.attach({
    name: open.name,
    attributes: open.attributes,
    children: open.children,
    position: open.position,
  })
}

///|
fn Parser::read_start_tag(self : Parser) -> Unit {
  let cursor = self.cursor
  let start = cursor.position()
  ignore(cursor.advance())
  let name = self.read_name(is_name_char)
  let attributes : Array[Attribute] = []
  let seen : Map[String, Unit] = Map([])
  while true {
    cursor.skip_whitespace()
    if cursor.at_end() {
      self.error("Unterminated start tag <\{name}>.", start)
      return
    }
    if cursor.looking_at("/>") {
      cursor.skip(2)
      self.attach({ name, attributes, children: [], position: start, })
      return
    }
    if cursor.peek() == '>' {
      ignore(cursor.advance())
      break
    }
    let attribute_start = cursor.position()
    let attribute_name = self.read_name(is_attribute_name_char)
    if attribute_name == "" {
      self.error(
        "Unexpected '\{cursor.peek()}' in <\{name}>.",
        cursor.position(),
      )
      ignore(cursor.advance())
      continue
    }
    cursor.skip_whitespace()
    let value = if cursor.peek() == '=' {
      ignore(cursor.advance())
      cursor.skip_whitespace()
      Some(self.read_attribute_value())
    } else {
      None
    }
    if seen.contains(attribute_name) {
      self.error(
        "Duplicate attribute '\{attribute_name}' on <\{name}>.",
        attribute_start,
      )
    }
    seen[attribute_name] = ()
    attributes.push({ name: attribute_name, value, position: attribute_start, })
  }
  if raw_text_elements.contains(name) {
    // Inline WXS module: skip to its closing tag without parsing markup.
    let closing = "</\{name}"
    while !cursor.at_end() && !cursor.looking_at(closing) {
      ignore(cursor.advance())
    }
    if cursor.at_end() {
      self.error("Unclosed <\{name}> element.", start)
      self.attach({ name, attributes, children: [], position: start, })
      return
    }
    cursor.skip(closing.length())
    cursor.skip_whitespace()
    if cursor.peek() == '>' {
      ignore(cursor.advance())
    }
    self.attach({ name, attributes, children: [], position: start, })
    return
  }
  self.stack.push({ name, attributes, children: [], position: start, })
}

///|
fn Parser::read_end_tag(self : Parser) -> Unit {
  let cursor = self.cursor
  let start = cursor.position()
  cursor.skip(2)
  let name = self.read_name(is_name_char)
  cursor.skip_whitespace()
  if cursor.peek() == '>' {
    ignore(cursor.advance())
  } else {
    self.error("Expected '>' to end </\{name}>.", start)
  }
  // Find the matching open element; anything above it was never closed.
  let mut match_index = -1
  for index = self.stack.length() - 1; index >= 0; index = index - 1 {
    if self.stack[index].name == name {
      match_index = index
      break
    }
  }
  if match_index < 0 {
    self.error("Closing tag </\{name}> has no matching start tag.", start)
    return
  }
  while self.stack.length() - 1 > match_index {
    let open = self.stack[self.stack.length() - 1]
    self.error("<\{open.name}> is not closed before </\{name}>.", open.position)
    self.close_top()
  }
  self.close_top()
}

///|
/// Parses WXML into an element tree. WXML requires every element to be
/// closed explicitly; unclosed and mismatched tags are reported with the
/// position of the offending start tag, and parsing recovers so later
/// references are still found.
pub fn parse(source : String) -> Document {
  let parser : Parser = {
    cursor: @scan.Cursor::new(source),
    stack: [],
    roots: [],
    errors: [],
  }
  let cursor = parser.cursor
  let text = StringBuilder()
  while !cursor.at_end() {
    if cursor.looking_at("<!--") {
      let start = cursor.position()
      while !cursor.at_end() && !cursor.looking_at("-->") {
        ignore(cursor.advance())
      }
      if cursor.at_end() {
        parser.error("Unterminated comment.", start)
      } else {
        cursor.skip(3)
      }
    } else if cursor.looking_at("</") {
      parser.read_end_tag()
    } else if cursor.peek() == '<' &&
      cursor.peek(offset=1).is_ascii_alphabetic() {
      parser.read_start_tag()
    } else if cursor.peek() == '<' {
      parser.error("Unexpected '<' in text.", cursor.position())
      ignore(cursor.advance())
    } else if cursor.looking_at("{{") {
      parser.skip_binding(text)
    } else {
      ignore(cursor.advance())
    }
  }
  while parser.stack.last() is Some(open) {
    parser.error("<\{open.name}> is never closed.", open.position)
    parser.close_top()
  }
  { roots: parser.roots, errors: parser.errors, }
}
