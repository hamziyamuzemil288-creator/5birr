/// Entry point.
///
/// Everything that used to live here now lives in `core/bootstrap.dart` —
/// error capture, the Supabase startup gate, the crash screen and the root
/// error boundary. This file is kept as the entry point `main()` because
/// Flutter's tooling and the release build both look for a `lib/main.dart`
/// with a top-level `main`; splitting the logic out is for readability, not
/// to move the entry point somewhere unusual.
library;

import 'core/bootstrap.dart' as bootstrap;

void main() => bootstrap.main();
