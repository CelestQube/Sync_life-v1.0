import 'package:flutter/foundation.dart';

/// Small invalidation signal; it carries no account data or cached record flags.
final activityUpdates = ValueNotifier<int>(0);
