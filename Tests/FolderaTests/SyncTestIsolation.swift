import Testing

/// These suites redirect the process-wide memory and profile directories.
/// Serializing each suite alone still lets another suite replace those paths
/// halfway through a sync. Keep their fixtures in one serialized parent.
@Suite(.serialized) struct SyncTestIsolation {}
