import Foundation
import SwiftUI

public protocol ObservableState {
  var _$id: StateID { get }
}

public struct StateID: Equatable, Hashable, Sendable {
  private let uuid: UUID
  private var tag: Int?
  public init() {
    self.uuid = UUID()
  }
  public func tagged(_ tag: Int?) -> Self {
    var copy = self
    copy.tag = tag
    return copy
  }
  public static let inert = StateID()
  public static func stateID<T>(for value: T) -> StateID {
    (value as? any ObservableState)?._$id ?? .inert
  }
  public static func stateID(for value: some ObservableState) -> StateID {
    value._$id
  }
}
extension StateID: CustomDebugStringConvertible {
  public var debugDescription: String {
    "StateID(\(self.uuid.description))"
  }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension Store: Observable {
  var observedState: State {
    get {
      self.access(keyPath: \.observedState)
      return self.subject.value
    }
    set {
      if isIdentityEqual(self.subject.value, newValue) {
        self.subject.value = newValue
      } else {
        self.withMutation(keyPath: \.observedState) {
          self.subject.value = newValue
        }
      }
    }
  }

  internal nonisolated func access<Member>(keyPath: KeyPath<Store, Member>) {
    _$observationRegistrar.rawValue.access(self, keyPath: keyPath)
  }

  internal nonisolated func withMutation<Member, T>(
    keyPath: KeyPath<Store, Member>,
    _ mutation: () throws -> T
  ) rethrows -> T {
    try _$observationRegistrar.rawValue.withMutation(of: self, keyPath: keyPath, mutation)
  }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension Store where State: ObservableState {
  private(set) public var state: State {
    get { self.observedState }
    set { self.observedState = newValue }
  }

  public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value>) -> Value {
    self.state[keyPath: keyPath]
  }

  public func binding<Value>(
    get: @escaping (_ state: State) -> Value,
    send valueToAction: @escaping (_ value: Value) -> Action
  ) -> Binding<Value> {
    ObservedObject(wrappedValue: self)
      .projectedValue[get: .init(rawValue: get), send: .init(rawValue: valueToAction)]
  }

  private subscript<Value>(
    get fromState: HashableWrapper<(State) -> Value>,
    send toAction: HashableWrapper<(Value) -> Action?>
  ) -> Value {
    get { fromState.rawValue(self.state) }
    set {
      BindingLocal.$isActive.withValue(true) {
        if let action = toAction.rawValue(newValue) {
          self.send(action)
        }
      }
    }
  }
}

// TODO: legit?
@available(iOS, introduced: 17)
@available(macOS, introduced: 14)
@available(tvOS, introduced: 17)
@available(watchOS, introduced: 10)
extension Store: ObservableObject where State: ObservableState {}


// TODO: optimize, benchmark
// TODO: Open enums to check isIdentityEqual to avoid requiring `enum State: ObservableState`
@available(iOS, introduced: 17)
@available(macOS, introduced: 14)
@available(tvOS, introduced: 17)
@available(watchOS, introduced: 10)
public func isIdentityEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
  if
    let oldID = (lhs as? any ObservableState)?._$id,
    let newID = (rhs as? any ObservableState)?._$id
  {
    return oldID == newID
  } else {

    func open<C: Collection>(_ lhs: C, _ rhs: Any) -> Bool {
      guard let rhs = rhs as? C else { return false }
      return lhs.count == rhs.count
      && zip(lhs, rhs).allSatisfy(isIdentityEqual)
    }

    if
      let lhs = lhs as? any Collection
    {
      return open(lhs, rhs)
    }

    return false
  }
}

@available(iOS, introduced: 17)
@available(macOS, introduced: 14)
@available(tvOS, introduced: 17)
@available(watchOS, introduced: 10)
public struct ObservationStateRegistrar: Codable, Equatable, Hashable, Sendable {
  public let id = StateID()
  public let _$observationRegistrar = ObservationRegistrar()
  public init() {}

  public func access<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>)
  where Subject: Observable {
    self._$observationRegistrar.access(subject, keyPath: keyPath)
  }

  public func willSet<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>)
  where Subject: Observable {
    self._$observationRegistrar.willSet(subject, keyPath: keyPath)
  }

  public func didSet<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>)
  where Subject: Observable {
    self._$observationRegistrar.didSet(subject, keyPath: keyPath)
  }

  public func withMutation<Subject, Member, T>(
    of subject: Subject, keyPath: KeyPath<Subject, Member>, _ mutation: () throws -> T
  ) rethrows -> T where Subject: Observable {
    try self._$observationRegistrar.withMutation(of: subject, keyPath: keyPath, mutation)
  }

  public init(from decoder: Decoder) throws {
    self.init()
  }
  public func encode(to encoder: Encoder) throws {}
}

// TODO: make Sendable
public struct ObservationRegistrarWrapper: Sendable {
  private let _rawValue: AnySendable

  public init() {
    if #available(iOS 17, tvOS 17, watchOS 10, macOS 14, *) {
      self._rawValue = AnySendable(ObservationRegistrar())
    } else {
      self._rawValue = AnySendable(())
    }
  }

  @available(iOS, introduced: 17)
  @available(macOS, introduced: 14)
  @available(tvOS, introduced: 17)
  @available(watchOS, introduced: 10)
  public init(rawValue: ObservationRegistrar) {
    self._rawValue = AnySendable(rawValue)
  }

  @available(iOS, introduced: 17)
  @available(macOS, introduced: 14)
  @available(tvOS, introduced: 17)
  @available(watchOS, introduced: 10)
  public var rawValue: ObservationRegistrar {
    self._rawValue.base as! ObservationRegistrar
  }
}

@available(iOS, introduced: 17)
@available(macOS, introduced: 14)
@available(tvOS, introduced: 17)
@available(watchOS, introduced: 10)
extension BindingAction {
  public static func set<Value: Equatable & Sendable>(
    _ keyPath: WritableKeyPath<Root, Value>,
    _ value: Value
  ) -> Self where Root: ObservableState {
    .init(
      keyPath: keyPath,
      set: { $0[keyPath: keyPath] = value },
      value: AnySendable(value),
      valueIsEqualTo: { ($0 as? AnySendable)?.base as? Value == value }
    )
  }

  public static func ~= <Value>(
    keyPath: WritableKeyPath<Root, Value>,
    bindingAction: Self
  ) -> Bool where Root: ObservableState {
    keyPath == bindingAction.keyPath
  }
}

@available(iOS, introduced: 17)
@available(macOS, introduced: 14)
@available(tvOS, introduced: 17)
@available(watchOS, introduced: 10)
extension Store where State: ObservableState, Action: BindableAction, Action.State == State {
  public subscript<Value: Equatable>(
    dynamicMember keyPath: WritableKeyPath<State, Value>
  ) -> Value {
    get { self.observedState[keyPath: keyPath] }
    set { self.send(.binding(.set(keyPath, newValue))) }
  }
}

@available(iOS, introduced: 17)
@available(macOS, introduced: 14)
@available(tvOS, introduced: 17)
@available(watchOS, introduced: 10)
extension Store
where
  State: ObservableState,
  Action: ViewAction,
  Action.ViewAction: BindableAction,
  Action.ViewAction.State == State
{
  public subscript<Value: Equatable>(
    dynamicMember keyPath: WritableKeyPath<State, Value>
  ) -> Value {
    get { self.observedState[keyPath: keyPath] }
    set { self.send(.view(.binding(.set(keyPath, newValue)))) }
  }
}

@available(iOS, introduced: 17)
@available(macOS, introduced: 14)
@available(tvOS, introduced: 17)
@available(watchOS, introduced: 10)
extension Binding {
  public subscript<State: ObservableState, Action: BindableAction, Member: Equatable>(
    dynamicMember keyPath: WritableKeyPath<State, Member>
  ) -> Binding<Member>
  where Value == Store<State, Action>, Action.State == State {
    Binding<Member>(
      get: { self.wrappedValue.state[keyPath: keyPath] },
      set: { self.transaction($1).wrappedValue.send(.binding(.set(keyPath, $0))) }
    )
  }

  public subscript<State: ObservableState, Action: ViewAction, Member: Equatable>(
    dynamicMember keyPath: WritableKeyPath<State, Member>
  ) -> Binding<Member>
  where 
    Value == Store<State, Action>,
    Action.ViewAction: BindableAction,
    Action.ViewAction.State == State
  {
    Binding<Member>(
      get: { self.wrappedValue.state[keyPath: keyPath] },
      set: { self.transaction($1).wrappedValue.send(.view(.binding(.set(keyPath, $0)))) }
    )
  }
}

extension Store: Equatable {
  public static func == (lhs: Store, rhs: Store) -> Bool {
    lhs === rhs
  }
}

extension Store: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

// TODO: Constrain?
extension Store {
  public func scope<ChildState, ChildAction>(
    state stateKeyPath: KeyPath<State, ChildState?>,
    action embedChildAction: @escaping (ChildAction) -> Action
  ) -> Store<ChildState, ChildAction>? {
    guard var childState = self.subject.value[keyPath: stateKeyPath]
    else {
      return nil
    }
    return self.scope(
      state: {
        childState = $0[keyPath: stateKeyPath] ?? childState
        return childState
      },
      action: embedChildAction
    )
  }
}

extension Binding {
  public func scope<State, Action, ChildState, ChildAction>(
    state toChildState: @escaping (State) -> ChildState,
    action embedChildAction: @escaping (ChildAction) -> Action
  )
    -> Binding<Store<ChildState, ChildAction>>
  where Value == Store<State, Action> {
    Binding<Store<ChildState, ChildAction>>(
      get: { self.wrappedValue.scope(state: toChildState, action: embedChildAction) },
      set: { _, _ in }
    )
  }

  public func scope<State, Action, ChildState, ChildAction>(
    state stateKeyPath: KeyPath<State, ChildState?>,
    action embedChildAction: @escaping (PresentationAction<ChildAction>) -> Action
  )
    -> Binding<Store<ChildState, ChildAction>?>
  where Value == Store<State, Action> {
    Binding<Store<ChildState, ChildAction>?>(
      get: {
        self.wrappedValue.scope(state: stateKeyPath, action: { embedChildAction(.presented($0)) })
      },
      set: {
        if $0 == nil {
          self.transaction($1).wrappedValue.send(embedChildAction(.dismiss))
        }
      }
    )
  }
}

extension Store: Identifiable {}