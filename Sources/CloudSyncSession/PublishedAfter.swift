import Combine

@propertyWrapper
class PublishedAfter<Value> {
    private var val: Value
    private let subject: CurrentValueSubject<Value, Never>

    init(wrappedValue value: Value) {
        val = value
        subject = CurrentValueSubject(value)
        wrappedValue = value
    }

    var wrappedValue: Value {
        set {
            val = newValue
            subject.send(val)
        }
        get { val }
    }

    public var projectedValue: CurrentValueSubject<Value, Never> {
        get { subject }
    }
}

