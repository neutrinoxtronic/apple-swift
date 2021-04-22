//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Swift
@_implementationOnly import _SwiftConcurrencyShims

// ==== TaskGroup --------------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {
  @available(*, deprecated, message: "`Task.Group` was replaced by `ThrowingTaskGroup` and `TaskGroup` and will be removed shortly.")
  public typealias Group<TaskResult: Sendable> = ThrowingTaskGroup<TaskResult, Error>

  @available(*, deprecated, message: "`Task.withGroup` was replaced by `withThrowingTaskGroup` and `withTaskGroup` and will be removed shortly.")
  public static func withGroup<TaskResult, BodyResult>(
      resultType: TaskResult.Type,
      returning returnType: BodyResult.Type = BodyResult.self,
      body: (inout Task.Group<TaskResult>) async throws -> BodyResult
  ) async rethrows -> BodyResult {
    try await withThrowingTaskGroup(of: resultType) { group in
      try await body(&group)
    }
  }
}


/// Starts a new scope in which a dynamic number of tasks can be spawned.
///
/// When the group returns,
/// it implicitly waits for all spawned tasks to complete.
/// The tasks are canceled only if `cancelAll()` was invoked before returning,
/// if the groups' task was canceled,
/// or if the group body throws an error.
/// ◊TR: Is it possible to throw an error here?
///
/// To collect the results of tasks that were added to the group,
/// use the following pattern:
///
///     while let result = await group.next() {
///         // some accumulation logic (e.g. sum += result)
///     }
///
/// It is also possible to collect results from the group by using its
/// `AsyncSequence` conformance, which enables its use in an asynchronous for-loop,
/// like this:
///
///     for await result in group {
///         // some accumulation logic (e.g. sum += result)
///      }
/// ◊TR: Which of the above do we prefer?  Why give two recommendations?
///
/// Task Group Cancellation
/// =======================
///
/// Canceling the task in which the group is running
/// also cancels the group and all of its child tasks.
///
/// Because the tasks you add to a group with this method are nonthrowing,
/// those tasks can't respond to cancellation by throwing `CancellationError`.
/// The tasks must handle cancellation in some other way,
/// such as returning the work completed so far, or returning `nil`.
/// For tasks that need to handle cancellation by throwing an error,
/// use the `withThrowingTaskGroup(of:returning:body:)` method instead.
///
/// After this method returns, the task group is guaranteed to be empty.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@inlinable
public func withTaskGroup<ChildTaskResult: Sendable, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout TaskGroup<ChildTaskResult>) async -> GroupResult
) async -> GroupResult {
  #if compiler(>=5.5) && $BuiltinTaskGroup

  let _group = Builtin.createTaskGroup()
  var group = TaskGroup<ChildTaskResult>(group: _group)

  // Run the withTaskGroup body.
  let result = await body(&group)

  await group.awaitAllRemainingTasks()

  Builtin.destroyTaskGroup(_group)
  return result

  #else
  fatalError("Swift compiler is incompatible with this SDK version")
  #endif
}

/// Starts a new scope in which a dynamic number of throwing tasks can be spawned.
///
/// When the group returns,
/// it implicitly waits for all spawned tasks to complete.
/// The tasks are canceled only if `cancelAll()` was invoked before returning,
/// if the groups' task was canceled,
/// or if the group body throws an error.
///
/// To collect the results of tasks that were added to the group,
/// use the following pattern:
///
///     while let result = await group.next() {
///         // some accumulation logic (e.g. sum += result)
///     }
///
/// It is also possible to collect results from the group by using its
/// `AsyncSequence` conformance, which enables its use in an asynchronous for-loop,
/// like this:
///
///     for await result in group {
///         // some accumulation logic (e.g. sum += result)
///      }
/// ◊TR: Which of the above do we prefer?  Why give two recommendations?
///
/// When tasks are added to the group
/// using the `Group.spawn(priority:operation:)` method,
/// they might begin executing immediately.
/// Even if their results are not collected explicitly and such task throws,
/// and was not yet canceled,
/// it may result in the `withTaskGroup` throwing.
/// ◊TR: What does the above "such task throws" mean?
///
/// Task Group Cancellation
/// =======================
///
/// Canceling the task in which the group is running
/// also cancels the group and all of its child tasks.
///
/// If an error is thrown by one of the tasks in a task group,
/// all of its remaining tasks are canceled,
/// and the `withTaskGroup` method rethrows that error.
///
/// An individual task throws its error
/// in the corresponding call to `Group.next()`,
/// which gives you a chance to handle individual error
/// or to let the error be rethrown by the group.
///
/// After this method returns, the task group is guaranteed to be empty.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@inlinable
public func withThrowingTaskGroup<ChildTaskResult: Sendable, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout ThrowingTaskGroup<ChildTaskResult, Error>) async throws -> GroupResult
) async rethrows -> GroupResult {
  #if compiler(>=5.5) && $BuiltinTaskGroup

  let _group = Builtin.createTaskGroup()
  var group = ThrowingTaskGroup<ChildTaskResult, Error>(group: _group)

  do {
    // Run the withTaskGroup body.
    let result = try await body(&group)

    await group.awaitAllRemainingTasks()
    Builtin.destroyTaskGroup(_group)

    return result
  } catch {
    group.cancelAll()

    await group.awaitAllRemainingTasks()
    Builtin.destroyTaskGroup(_group)

    throw error
  }

  #else
  fatalError("Swift compiler is incompatible with this SDK version")
  #endif
}

/// A task group serves as storage for dynamically spawned child tasks.
///
/// To create a task group,
/// call the `withTaskGroup(of:returning:body:)` method.
///
/// A task group most be used only within the task where it was created.
/// In most cases,
/// the Swift type system prevents a task group from escaping like that
/// because adding a child task is a mutating operation,
/// and mutation operations can't be performed
/// from concurrent execution contexts likes child tasks.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@frozen
public struct TaskGroup<ChildTaskResult: Sendable> {

  /// Group task into which child tasks offer their results,
  /// and the `next()` function polls those results from.
  @usableFromInline
  internal let _group: Builtin.RawPointer

  /// No public initializers
  @inlinable
  init(group: Builtin.RawPointer) {
    self._group = group
  }

  @available(*, deprecated, message: "`Task.Group.add` has been replaced by `TaskGroup.spawn` or `TaskGroup.spawnUnlessCancelled` and will be removed shortly.")
  public mutating func add(
      priority: Task.Priority = .unspecified,
      operation: __owned @Sendable @escaping () async -> ChildTaskResult
  ) async -> Bool {
    return try self.spawnUnlessCancelled(priority: priority) {
      await operation()
    }
  }

  /// Adds a child task to the group.
  ///
  /// - Parameters:
  ///   - overridingPriority: The priority of the operation task.
  ///     Omit this parameter or pass `.unspecified`
  ///     to set the child task's priority to the priority of the group.
  ///   - operation: The operation to execute as part of the task group.
  /// - Returns: `true` if the operation was added to the group successfully;
  ///   otherwise; `false`.
  public mutating func spawn(
    priority: Task.Priority = .unspecified,
    operation: __owned @Sendable @escaping () async -> ChildTaskResult
  ) {
    _ = _taskGroupAddPendingTask(group: _group, unconditionally: true)

    // Set up the job flags for a new task.
    var flags = Task.JobFlags()
    flags.kind = .task
    flags.priority = priority
    flags.isFuture = true
    flags.isChildTask = true
    flags.isGroupChildTask = true
    
    // Create the asynchronous task future.
    let (childTask, _) = Builtin.createAsyncTaskGroupFuture(
      flags.bits, _group, operation)
    
    // Attach it to the group's task record in the current task.
    _ = _taskGroupAttachChild(group: _group, child: childTask)
    
    // Enqueue the resulting job.
    _enqueueJobGlobal(Builtin.convertTaskToJob(childTask))
  }

  /// Adds a child task to the group, unless the group has been canceled.
  ///
  /// - Parameters:
  ///   - overridingPriority: The priority of the operation task.
  ///     Omit this parameter or pass `.unspecified`
  ///     to set the child task's priority to the priority of the group.
  ///   - operation: The operation to execute as part of the task group.
  /// - Returns: `true` if the operation was added to the group successfully;
  ///   otherwise; `false`.
  public mutating func spawnUnlessCancelled(
    priority: Task.Priority = .unspecified,
    operation: __owned @Sendable @escaping () async -> ChildTaskResult
  ) -> Bool {
    let canAdd = _taskGroupAddPendingTask(group: _group, unconditionally: false)

    guard canAdd else {
      // the group is cancelled and is not accepting any new work
      return false
    }

    // Set up the job flags for a new task.
    var flags = Task.JobFlags()
    flags.kind = .task
    flags.priority = priority
    flags.isFuture = true
    flags.isChildTask = true
    flags.isGroupChildTask = true

    // Create the asynchronous task future.
    let (childTask, _) = Builtin.createAsyncTaskGroupFuture(
      flags.bits, _group, operation)

    // Attach it to the group's task record in the current task.
    _ = _taskGroupAttachChild(group: _group, child: childTask)

    // Enqueue the resulting job.
    _enqueueJobGlobal(Builtin.convertTaskToJob(childTask))

    return true
  }

  /// Wait for the next child task to complete,
  /// and return the value it returned.
  ///
  /// The values returned by successive calls to this method
  /// appear in the order that the tasks *completed*,
  /// not in the order that those tasks were added to the task group.
  /// For example:
  ///
  ///     group.spawn { 1 }
  ///     group.spawn { 2 }
  ///
  ///     print(await group.next())
  ///     // Prints either "2" or "1"
  ///
  /// If there aren't any pending tasks in the task group,
  /// this method returns `nil`,
  /// which lets you write like the following
  /// to wait for a single task to complete:
  ///
  ///     if let first = try await group.next() {
  ///        return first
  ///     }
  ///
  /// Wait and collect all group child task completions:
  ///
  ///     while let first = try await group.next() {
  ///        collected += value
  ///     }
  ///     return collected
  ///
  /// Awaiting on an empty group results in the immediate return of a `nil`
  /// value, without the group task having to suspend.
  ///
  /// It is also possible to use `for await` to collect results of a task groups:
  ///
  ///     for await try value in group {
  ///         collected += value
  ///     }
  ///
  /// - Returns: The value returned by the next child task that completes.
  public mutating func next() async -> ChildTaskResult? {
    // try!-safe because this function only exists for Failure == Never,
    // and as such, it is impossible to spawn a throwing child task.
    return try! await _taskGroupWaitNext(group: _group)
  }

  /// Await all the remaining tasks on this group.
  @usableFromInline
  internal mutating func awaitAllRemainingTasks() async {
    while let _ = await next() {}
  }
  
  /// A Boolean value that indicates whether the group has any remaining tasks.
  ///
  /// At the start of the body of a `withTaskGroup(of:returning:body:)` call,
  /// the task group is always empty.
  /// It is guaranteed to be empty when returning from that body,
  /// either because all child tasks have completed
  /// or because they've been canceled.
  ///
  /// - Returns: `true` if the group has no pending tasks, `false` otherwise.
  public var isEmpty: Bool {
    _taskGroupIsEmpty(_group)
  }

  /// Cancel all the remaining tasks in the group.
  ///
  /// After canceling a group, adding a new task to it always fails.
  ///
  /// Any results, including errors thrown by tasks affected by this
  /// cancellation, are silently discarded.
  ///
  /// This function may be called even from within child (or any other) tasks,
  /// and will reliably cause the group to become canceled.
  ///
  /// - SeeAlso: `Task.isCancelled`
  /// - SeeAlso: `TaskGroup.isCancelled`
  public func cancelAll() {
    _taskGroupCancelAll(group: _group)
  }

  /// A Boolean value that indicates whether the group was canceled.
  ///
  /// To cancel a group, call the `TaskGroup.cancelAll()` method.
  ///
  /// If the task that's currently running this group is canceled,
  /// the group is also implicitly canceled,
  /// which is also reflected in this property's value.
  public var isCancelled: Bool {
    return _taskGroupIsCancelled(group: _group)
  }
}

// Implementation note:
// We are unable to just™ abstract over Failure == Error / Never because of the
// complicated relationship between `group.spawn` which dictates if `group.next`
// AND the AsyncSequence conformances would be throwing or not.
//
// We would be able to abstract over TaskGroup<..., Failure> equal to Never
// or Error, and specifically only add the `spawn` and `next` functions for
// those two cases. However, we are not able to conform to AsyncSequence "twice"
// depending on if the Failure is Error or Never, as we'll hit:
//    conflicting conformance of 'TaskGroup<ChildTaskResult, Failure>' to protocol
//    'AsyncSequence'; there cannot be more than one conformance, even with
//    different conditional bounds
// So, sadly we're forced to duplicate the entire implementation of TaskGroup
// to TaskGroup and ThrowingTaskGroup.
//
// The throwing task group is parameterized with failure only because of future
// proofing, in case we'd ever have typed errors, however unlikely this may be.
// Today the throwing task group failure is simply automatically bound to `Error`.

/// A task group serves as storage for dynamically spawned tasks,
/// potentially throwing, child tasks.
///
/// To create a throwing task group,
/// call the `withThrowingTaskGroup(of:returning:body:)` method.
///
/// A task group most be used only within the task where it was created.
/// In most cases,
/// the Swift type system prevents a task group from escaping like that
/// because adding a child task is a mutating operation,
/// and mutation operations can't be performed
/// from concurrent execution contexts likes child tasks.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@frozen
public struct ThrowingTaskGroup<ChildTaskResult: Sendable, Failure: Error> {

  /// Group task into which child tasks offer their results,
  /// and the `next()` function polls those results from.
  @usableFromInline
  internal let _group: Builtin.RawPointer

  /// No public initializers
  @inlinable
  init(group: Builtin.RawPointer) {
    self._group = group
  }

  /// Await all the remaining tasks on this group.
  @usableFromInline
  internal mutating func awaitAllRemainingTasks() async {
    while true {
      do {
        guard let _ = try await next() else {
          return
        }
      } catch {}
    }
  }

  @available(*, deprecated, message: "`Task.Group.add` has been replaced by `(Throwing)TaskGroup.spawn` or `(Throwing)TaskGroup.spawnUnlessCancelled` and will be removed shortly.")
  public mutating func add(
    priority: Task.Priority = .unspecified,
    operation: __owned @Sendable @escaping () async throws -> ChildTaskResult
  ) async -> Bool {
    return try self.spawnUnlessCancelled(priority: priority) {
      try await operation()
    }
  }

  /// Adds a child task to the group.
  ///
  /// This method doesn't throw an error, even if the child task throws.
  /// Instead, the next call to `TaskGroup.next()` rethrows that error.
  ///
  /// - Parameters:
  ///   - overridingPriority: The priority of the operation task.
  ///     Omit this parameter or pass `.unspecified`
  ///     to set the child task's priority to the priority of the group.
  ///   - operation: The operation to execute as part of the task group.
  /// - Returns: `true` if the operation was added to the group successfully;
  ///   otherwise; `false`.
  public mutating func spawn(
    priority: Task.Priority = .unspecified,
    operation: __owned @Sendable @escaping () async throws -> ChildTaskResult
  ) {
    // we always add, so no need to check if group was cancelled
    _ = _taskGroupAddPendingTask(group: _group, unconditionally: true)

    // Set up the job flags for a new task.
    var flags = Task.JobFlags()
    flags.kind = .task
    flags.priority = priority
    flags.isFuture = true
    flags.isChildTask = true
    flags.isGroupChildTask = true

    // Create the asynchronous task future.
    let (childTask, _) = Builtin.createAsyncTaskGroupFuture(
      flags.bits, _group, operation)

    // Attach it to the group's task record in the current task.
    _ = _taskGroupAttachChild(group: _group, child: childTask)

    // Enqueue the resulting job.
    _enqueueJobGlobal(Builtin.convertTaskToJob(childTask))
  }

  /// Adds a child task to the group, unless the group has been canceled.
  ///
  /// This method doesn't throw an error, even if the child task throws.
  /// Instead, the next call to `TaskGroup.next()` rethrows that error.
  ///
  /// - Parameters:
  ///   - overridingPriority: The priority of the operation task.
  ///     Omit this parameter or pass `.unspecified`
  ///     to set the child task's priority to the priority of the group.
  ///   - operation: The operation to execute as part of the task group.
  /// - Returns: `true` if the operation was added to the group successfully;
  ///   otherwise; `false`.
  public mutating func spawnUnlessCancelled(
    priority: Task.Priority = .unspecified,
    operation: __owned @Sendable @escaping () async throws -> ChildTaskResult
  ) -> Bool {
    let canAdd = _taskGroupAddPendingTask(group: _group, unconditionally: false)

    guard canAdd else {
      // the group is cancelled and is not accepting any new work
      return false
    }

    // Set up the job flags for a new task.
    var flags = Task.JobFlags()
    flags.kind = .task
    flags.priority = priority
    flags.isFuture = true
    flags.isChildTask = true
    flags.isGroupChildTask = true

    // Create the asynchronous task future.
    let (childTask, _) = Builtin.createAsyncTaskGroupFuture(
      flags.bits, _group, operation)

    // Attach it to the group's task record in the current task.
    _ = _taskGroupAttachChild(group: _group, child: childTask)

    // Enqueue the resulting job.
    _enqueueJobGlobal(Builtin.convertTaskToJob(childTask))

    return true
  }

  /// Wait for the next child task to complete,
  /// and return the value it returned or rethrow the error it threw.
  ///
  /// The values returned by successive calls to this method
  /// appear in the order that the tasks *completed*,
  /// not in the order that those tasks were added to the task group.
  /// For example:
  ///
  ///     group.spawn { 1 }
  ///     group.spawn { 2 }
  ///
  ///     print(await group.next())
  ///     // Prints either "2" or "1"
  ///
  /// If there aren't any pending tasks in the task group,
  /// this method returns `nil`,
  /// which lets you write like the following
  /// to wait for a single task to complete:
  ///
  ///     if let first = try await group.next() {
  ///        return first
  ///     }
  ///
  /// Wait and collect all group child task completions:
  ///
  ///     while let first = try await group.next() {
  ///        collected += value
  ///     }
  ///     return collected
  ///
  /// Awaiting on an empty group results in the immediate return of a `nil`
  /// value, without the group task having to suspend.
  ///
  /// It is also possible to use `for await` to collect results of a task groups:
  ///
  ///     for await try value in group {
  ///         collected += value
  ///     }
  ///
  /// If the next child task throws an error
  /// and you propagate that error from this method
  /// out of the body of a `TaskGroup.withThrowingTaskGroup(of:returning:body:)` call,
  /// then all remaining child tasks in that group are implicitly canceled.
  ///
  /// - Returns: The value returned by the next child task that completes.
  ///
  /// - Throws: The error thrown by the next child task that completes.
  ///
  /// - SeeAlso: `nextResult()`
  public mutating func next() async throws -> ChildTaskResult? {
    return try await _taskGroupWaitNext(group: _group)
  }

  /// Wait for the next child task to complete,
  /// and return a result containing either
  /// the value that the child task returned or the error that it threw.
  ///
  /// The values returned by successive calls to this method
  /// appear in the order that the tasks *completed*,
  /// not in the order that those tasks were added to the task group.
  /// For example:
  ///
  ///     group.spawn { 1 }
  ///     group.spawn { 2 }
  ///
  ///     print(await group.nextResult())
  ///     // Prints either "2" or "1"
  ///
  /// If there aren't any pending tasks in the task group,
  /// this method returns `nil`,
  /// which lets you write like the following
  /// to wait for a single task to complete:
  ///
  ///     if let first = try await group.next() {
  ///        return first
  ///     }
  ///
  /// Wait and collect all group child task completions:
  ///
  ///     while let first = try await group.next() {
  ///        collected += value
  ///     }
  ///     return collected
  ///
  /// Awaiting on an empty group results in the immediate return of a `nil`
  /// value, without the group task having to suspend.
  ///
  /// It is also possible to use `for await` to collect results of a task groups:
  ///
  ///     for await try value in group {
  ///         collected += value
  ///     }
  ///
  /// If the next child task throws an error
  /// and you propagate that error from this method
  /// out of the body of a `ThrowingTaskGroup.withThrowingTaskGroup(of:returning:body:)` call,
  /// then all remaining child tasks in that group are implicitly canceled.
  ///
  /// - Returns: A `Result.success` value
  ///   containing the value that the child task returned,
  ///   or a `Result.failure` value
  ///   containing the error that the child task threw.
  ///
  /// - SeeAlso: `next()`
  public mutating func nextResult() async throws -> Result<ChildTaskResult, Failure>? {
    do {
      guard let success: ChildTaskResult = try await _taskGroupWaitNext(group: _group) else {
        return nil
      }

      return .success(success)
    } catch {
      return .failure(error as! Failure) // as!-safe, because we are only allowed to throw Failure (Error)
    }
  }

  /// A Boolean value that indicates whether the group has any remaining tasks.
  ///
  /// At the start of the body of a `withThrowingTaskGroup(of:returning:body:)` call,
  /// the task group is always empty.
  /// It is guaranteed to be empty when returning from that body,
  /// either because all child tasks have completed
  /// or because they've been canceled.
  ///
  /// - Returns: `true` if the group has no pending tasks, `false` otherwise.
  public var isEmpty: Bool {
    _taskGroupIsEmpty(_group)
  }

  /// Cancel all the remaining tasks in the group.
  ///
  /// After canceling a group, adding a new task to it always fails.
  ///
  /// Any results, including errors thrown by tasks affected by this
  /// cancellation, are silently discarded.
  ///
  /// This function may be called even from within child (or any other) tasks,
  /// and will reliably cause the group to become canceled.
  ///
  /// - SeeAlso: `Task.isCancelled`
  /// - SeeAlso: `TaskGroup.isCancelled`
  public func cancelAll() {
    _taskGroupCancelAll(group: _group)
  }

  /// A Boolean value that indicates whether the group was canceled.
  ///
  /// To cancel a group, call the `ThrowingTaskGroup.cancelAll()` method.
  ///
  /// If the task that's currently running this group is canceled,
  /// the group is also implicitly canceled,
  /// which is also reflected in this property's value.
  public var isCancelled: Bool {
    return _taskGroupIsCancelled(group: _group)
  }
}

/// ==== TaskGroup: AsyncSequence ----------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension TaskGroup: AsyncSequence {
  public typealias AsyncIterator = Iterator
  public typealias Element = ChildTaskResult

  public func makeAsyncIterator() -> Iterator {
    return Iterator(group: self)
  }

  /// A type that provides an iteration interface
  /// over the results of tasks added to the group.
  ///
  /// The elements returned by this iterator
  /// appear in the order that the tasks *completed*,
  /// not in the order that those tasks were added to the task group.
  ///
  /// This iterator terminates after all tasks have completed successfully,
  /// or after any task completes by throwing an error.
  /// If a task completes by throwing an error,
  /// no further task results are returned.
  ///
  /// - SeeAlso: `TaskGroup.next()`
  @available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
  public struct Iterator: AsyncIteratorProtocol {
    public typealias Element = ChildTaskResult

    @usableFromInline
    var group: TaskGroup<ChildTaskResult>

    @usableFromInline
    var finished: Bool = false

    // no public constructors
    init(group: TaskGroup<ChildTaskResult>) {
      self.group = group
    }

    /// Advances to the result of the next child task,
    /// or `nil` if there are no remaining child tasks,
    /// rethrowing an error if the child task threw.
    ///
    /// The elements returned from this method
    /// appear in the order that the tasks *completed*,
    /// not in the order that those tasks were added to the task group.
    /// After this method returns `nil`,
    /// this iterater is guaranteed to never produce more values.
    ///
    /// For more information about the iteration order and semantics,
    /// see `TaskGroup.next()`.
    public mutating func next() async -> Element? {
      guard !finished else { return nil }
      guard let element = await group.next() else {
        finished = true
        return nil
      }
      return element
    }

    public mutating func cancel() {
      finished = true
      group.cancelAll()
    }
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension ThrowingTaskGroup: AsyncSequence {
  public typealias AsyncIterator = Iterator
  public typealias Element = ChildTaskResult

  public func makeAsyncIterator() -> Iterator {
    return Iterator(group: self)
  }

  /// A type that provides an iteration interface
  /// over the results of tasks added to the group.
  ///
  /// The elements returned by this iterator
  /// appear in the order that the tasks *completed*,
  /// not in the order that those tasks were added to the task group.
  ///
  /// This iterator terminates after all tasks have completed successfully,
  /// or after any task completes by throwing an error.
  /// If a task completes by throwing an error,
  /// no further task results are returned.
  ///
  /// - SeeAlso: `ThrowingTaskGroup.next()`
  @available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
  public struct Iterator: AsyncIteratorProtocol {
    public typealias Element = ChildTaskResult

    @usableFromInline
    var group: ThrowingTaskGroup<ChildTaskResult, Failure>

    @usableFromInline
    var finished: Bool = false

    // no public constructors
    init(group: ThrowingTaskGroup<ChildTaskResult, Failure>) {
      self.group = group
    }

    /// Advances to the result of the next child task,
    /// or `nil` if there are no remaining child tasks,
    /// rethrowing an error if the child task threw.
    ///
    /// The elements returned from this method
    /// appear in the order that the tasks *completed*,
    /// not in the order that those tasks were added to the task group.
    /// After this method returns `nil`,
    /// this iterater is guaranteed to never produce more values.
    ///
    /// For more information about the iteration order and semantics,
    /// see `ThrowingTaskGroup.next()` 
    public mutating func next() async throws -> Element? {
      guard !finished else { return nil }
      do {
        guard let element = try await group.next() else {
          finished = true
          return nil
        }
        return element
      } catch {
        finished = true
        throw error
      }
    }

    public mutating func cancel() {
      finished = true
      group.cancelAll()
    }
  }
}

/// ==== -----------------------------------------------------------------------

/// Attach task group child to the group group to the task.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_attachChild")
func _taskGroupAttachChild(
  group: Builtin.RawPointer,
  child: Builtin.NativeObject
) -> UnsafeRawPointer /*ChildTaskStatusRecord*/

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_destroy")
func _taskGroupDestroy(group: __owned Builtin.RawPointer)

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_addPending")
func _taskGroupAddPendingTask(
  group: Builtin.RawPointer,
  unconditionally: Bool
) -> Bool

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_cancelAll")
func _taskGroupCancelAll(group: Builtin.RawPointer)

/// Checks ONLY if the group was specifically canceled.
/// The task itself being canceled must be checked separately.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_isCancelled")
func _taskGroupIsCancelled(group: Builtin.RawPointer) -> Bool

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_wait_next_throwing")
func _taskGroupWaitNext<T>(group: Builtin.RawPointer) async throws -> T?

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
enum PollStatus: Int {
  case empty   = 0
  case waiting = 1
  case success = 2
  case error   = 3
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_isEmpty")
func _taskGroupIsEmpty(
  _ group: Builtin.RawPointer
) -> Bool
