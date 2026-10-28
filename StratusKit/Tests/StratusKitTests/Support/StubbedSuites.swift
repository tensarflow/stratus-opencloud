import Testing

/// Parent for every suite that installs a `StubURLProtocol` handler. The stub's state is
/// process-wide, so these suites must not run in parallel with each other.
@Suite(.serialized) enum StubbedSuites {}
