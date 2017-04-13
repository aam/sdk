// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "package:expect/expect.dart";

// Checks that specialized truncated division works as expected.

f(x) => x ~/ 10;
f_(x) => (x / 10).truncate();

main() {
	var sum = 0;
	// Range long enough for VM to optimize f(x), f_(x).
	for (var i = -1000000+1; i < 1000000; i++) {
	    sum += f(i);
	    Expect.equals(f(i), f_(i));
	}
	Expect.equals(sum, 0);
}