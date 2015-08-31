// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Note: This test relies on LF line endings in the source file.

import "package:expect/expect.dart";

// Test that String interpolation works in the code generated by the leg
// compiler.


int ifun() => 37;
double dfun() => 2.71828;
bool bfun() => true;
String sfun() => "sfun";
void nfun() => null;


void testEscapes() {
  // Test that escaping the '$' prevents string interpolation.
  String x = "NOT HERE";
  Expect.equals(r'a${x}', 'a\${x}');
  Expect.equals(r'a$x', 'a\$x');
  Expect.equals(r'a${x}', '''a\${x}''');
  Expect.equals(r'a$x', '''a\$x''');
  Expect.equals(r'a${x}', "a\${x}");
  Expect.equals(r'a$x', "a\$x");
  Expect.equals(r'a${x}', """a\${x}""");
  Expect.equals(r'a$x', """a\$x""");
}


void testMultiLine() {
  var a = "string";
  var b = 42;
  var c = 3.1415;
  var d = false;
  var n = null;

  Expect.equals("string423.1415falsenull!", """$a$b$c$d$n!""");
  Expect.equals("string423.1415falsenull!", '''$a$b$c$d$n!''');
  Expect.equals("string423.1415falsenull!", """${a}${b}${c}${d}${n}!""");
  Expect.equals("string423.1415falsenull!", '''${a}${b}${c}${d}${n}!''');

  // Quotes as literals are included correctly..
  Expect.equals("'42''42'", """'$b''$b'""");
  Expect.equals('"42""42"', '''"$b""$b"''');

  Expect.equals('"42""42" ', """"$b""$b" """);
  Expect.equals("'42''42' ", ''''$b''$b' ''');

  Expect.equals('""42""42" ', """""$b""$b" """);
  Expect.equals("''42''42' ", '''''$b''$b' ''');

  // Newlines at beginning of multiline strings are not included, but only
  // if they are in the source.
  Expect.equals("\n", """${''}
""");
  Expect.equals("\r", """${''}""");
  Expect.equals("\r\n", """${''}
""");
  Expect.equals("\n", """${'\n'}""");
  Expect.equals("\r", """${'\r'}""");
  Expect.equals("\r\n", """${'\r\n'}""");
}


void testSimple() {
  var a = "string";
  var b = 42;
  var c = 3.1415;
  var d = false;
  var n = null;

  // Both kinds of quotes and both kinds of $-escapes.
  Expect.equals("string423.1415falsenull!", "$a$b$c$d$n!");
  Expect.equals("string423.1415falsenull!", '$a$b$c$d$n!');
  Expect.equals("string423.1415falsenull!", "${a}${b}${c}${d}${n}!");
  Expect.equals("string423.1415falsenull!", '${a}${b}${c}${d}${n}!');

  // Different types for first expression.
  Expect.equals("!string423.1415falsenull", "!$a$b$c$d$n");
  Expect.equals("null!string423.1415false", "$n!$a$b$c$d");
  Expect.equals("falsenull!string423.1415", "$d$n!$a$b$c");
  Expect.equals("3.1415falsenull!string42", "$c$d$n!$a$b");
  Expect.equals("423.1415falsenull!string", "$b$c$d$n!$a");

  // Function calls as expressions.
  Expect.equals("sfun372.71828truenull",
                "${sfun()}${ifun()}${dfun()}${bfun()}${nfun()}");
  Expect.equals("nullsfun372.71828true",
                "${nfun()}${sfun()}${ifun()}${dfun()}${bfun()}");
  Expect.equals("truenullsfun372.71828",
                "${bfun()}${nfun()}${sfun()}${ifun()}${dfun()}");
  Expect.equals("2.71828truenullsfun37",
                "${dfun()}${bfun()}${nfun()}${sfun()}${ifun()}");
  Expect.equals("372.71828truenullsfun",
                "${ifun()}${dfun()}${bfun()}${nfun()}${sfun()}");


  // String contents around interpolated parts.
  Expect.equals("stringstring", "$a$a");
  Expect.equals("-stringstring", "-$a$a");
  Expect.equals("string-string", "$a-$a");
  Expect.equals("-string-string", "-$a-$a");
  Expect.equals("stringstring-", "$a$a-");
  Expect.equals("-stringstring-", "-$a$a-");
  Expect.equals("string-string-", "$a-$a-");
  Expect.equals("-string-string-", "-$a-$a-");

  // Quotes as literals are included correctly..
  Expect.equals("'42''42'", "'$b''$b'");
  Expect.equals('"42""42"', '"$b""$b"');

  // Nested string interpolation.
  Expect.equals("string423.1415false", "${'${a}'}$b${'$c${d}'}");
  // Quad-nested string interpolation.
  Expect.equals("string423.1415false", "${'${a}${"${b}${'${c}${"$d"}'}"}'}");
  // Lotsa-nested.
  Expect.equals("42", "${'${"${'${"${'${"$b"}'}"}'}"}'}");
}


void main() {
  testSimple();
  testMultiLine();
  testEscapes();
}
