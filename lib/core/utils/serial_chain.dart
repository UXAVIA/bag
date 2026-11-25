/// Runs bodies one at a time, in call order: each starts once the previous
/// one has finished. The chain is extended synchronously, so two calls in
/// the same turn still run in the order they were made. A body that fails
/// fails its own call only; the next one still runs.
class SerialChain {
  Future<void> _tail = Future.value();

  Future<void> run(Future<void> Function() body) {
    final run = _tail.then((_) => body());
    // A failed body must not wedge every later one.
    _tail = run.catchError((_) {});
    return run;
  }
}
