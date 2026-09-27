// This file is generated, not hand-maintained.
//
// `flutter create` derives this package from the Flutter project name in
// pubspec.yaml (`name: birr5`), while the Android namespace and applicationId
// are `com.amistbirr.myapp`. That mismatch means every CI run of
// `flutter create --platforms=android,ios .` recreates this file alongside
// the real one in com/amistbirr/myapp/.
//
// It is harmless. The manifest declares `android:name=".MainActivity"`, which
// the build resolves against the namespace, so only
// com/amistbirr/myapp/MainActivity.kt is ever instantiated. This class
// compiles and is never launched.
//
// Deleting it does not help: the next CI run recreates it, finds the tree
// dirty, and tries to commit it back. Aligning the two would mean renaming
// the Flutter project (lib/, test/, and every import), which is a far larger
// change than the cosmetic duplicate justifies.
package com.amistbirr.birr5

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
