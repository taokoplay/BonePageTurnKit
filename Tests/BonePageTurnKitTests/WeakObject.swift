/// 用于对象释放断言；盒子自身不延长被测对象的生命周期。
final class WeakObject<Object: AnyObject> {
    weak var value: Object?

    /// - Parameter value: 被观察对象，可以为 nil。
    init(_ value: Object?) { self.value = value }
}
