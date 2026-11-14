/// Carries a value the compiler cannot prove safe to hand from one thread to another, on the
/// strength of a rule the session keeps instead.
///
/// The run loop uses it to hand one piece of work to the task that carries it out and to take the
/// result back. Only one of the two touches the value at a time: the loop does not look at the
/// work again until the operation's task has finished.
///
/// The async streams and `perform` use it to hand out events, responses and states. Those are the
/// same values the Combine subjects hand to every subscriber, and the same rule covers them: the
/// session is done with a value before it gives it away, and what its receivers do with a record
/// they share is theirs to coordinate.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}
