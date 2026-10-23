import Flutter
import Foundation
import CoreFoundation
import UIKit

#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
import AlarmKit
import AppIntents
import SwiftUI
#endif

/// The platform channel is present even on a toolchain without AlarmKit.
@MainActor
final class FiveMoreAlarmBridge: NSObject {
  private let channel: FlutterMethodChannel
  private var implementation: AnyObject?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "five_more/alarm", binaryMessenger: messenger)
    super.init()
    #if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
    if #available(iOS 26.0, *) {
      let engine = FiveMoreAlarmEngine()
      implementation = engine
      channel.setMethodCallHandler { call, result in
        Task { @MainActor in await engine.handle(call, result: result) }
      }
      return
    }
    #endif
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        result([
          "platform": "ios", "supported": false, "exactAlarms": false,
          "notifications": false, "fullScreenIntent": false,
          "challengeEnforced": false, "scheduledCount": 0, "alarms": [],
          "error": "Для будильника нужен iOS 26 или новее и сборка с AlarmKit.",
        ])
      case "getRingingAlarm": result(nil)
      case "drainEvents": result([])
      case "ackEvents": result(["ok": true])
      default:
        result(["ok": false, "error": "На этом устройстве доступна только тренировка."])
      }
    }
  }
}

#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
@available(iOS 26.0, *)
private struct FiveMoreAlarmMetadata: AlarmMetadata {
  var logicalID: String
}

/// All store operations and App Intents execute on the main actor. Intents run
/// in the app process; no extension/App Group or background Dart isolate is used.
@MainActor
private enum FiveMoreAlarmStore {
  static let key = "fiveMore.nativeAlarms.v1"
  static var data: [String: Any] {
    get { UserDefaults.standard.dictionary(forKey: key) ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }

  static var configurations: [String: [String: Any]] {
    get {
      let saved = data["configurations"] as? [String: [String: Any]] ?? [:]
      return saved.mapValues { original in
        var config = original
        // Legacy occurrences keep their original difficulty until the user opts in.
        // The next configuration write persists this additive default.
        if config["escalateOnSnooze"] == nil { config["escalateOnSnooze"] = false }
        if config["moveSnoozeButton"] == nil { config["moveSnoozeButton"] = false }
        return config
      }
    }
    set { var root = data; root["configurations"] = newValue; data = root }
  }

  static var instances: [String: [String: Any]] {
    get { data["instances"] as? [String: [String: Any]] ?? [:] }
    set { var root = data; root["instances"] = newValue; data = root }
  }

  static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  static func appendEvent(_ record: [String: Any], type: String, nextAt: Int64? = nil) {
    var root = data
    var events = root["events"] as? [[String: Any]] ?? []
    var event: [String: Any] = [
      "eventId": UUID().uuidString, "id": record["id"] as? String ?? "",
      "occurrenceId": record["occurrenceId"] as? String ?? "",
      "type": type, "at": now(), "snoozesUsed": record["snoozesUsed"] as? Int ?? 0,
    ]
    if let nextAt { event["nextAt"] = nextAt }
    events.append(event)
    root["events"] = Array(events.suffix(1000))
    data = root
  }

  static func drainEvents() -> [[String: Any]] {
    // The historical channel name is retained, but this is a non-destructive
    // peek. Dart acknowledges event IDs only after its own durable write.
    data["events"] as? [[String: Any]] ?? []
  }

  static func acknowledgeEvents(_ ids: [String]) {
    let accepted = Set(ids)
    var root = data
    let events = root["events"] as? [[String: Any]] ?? []
    root["events"] = events.filter { !accepted.contains($0["eventId"] as? String ?? "") }
    data = root
  }

  static func suppressSystemStop(_ systemID: String, until: Int64?) {
    var all = instances
    guard var record = all[systemID] else { return }
    if let until { record["appStopUntil"] = until }
    else { record.removeValue(forKey: "appStopUntil") }
    all[systemID] = record
    instances = all
  }

  /// Remove expired action guards and abandoned transient records without
  /// treating a missing daemon entry as proof of successful delivery. A grace
  /// period allows a delayed Stop intent to record its event first.
  static func pruneTransientState(liveSystemIDs: Set<String>) {
    let timestamp = now()
    var all = instances
    var changed = false
    for (systemID, original) in all {
      var record = original
      for key in ["appStopUntil", "ignoreAlertsUntil"] {
        if let until = record[key] as? NSNumber, until.int64Value <= timestamp {
          record.removeValue(forKey: key)
          changed = true
        }
      }
      let expectedAt = (record["nextAt"] as? NSNumber)?.int64Value ?? timestamp
      let transient = record["kind"] as? String != "base"
      if transient, !liveSystemIDs.contains(systemID),
        expectedAt + 86_400_000 < timestamp {
        all.removeValue(forKey: systemID)
        changed = true
      } else {
        all[systemID] = record
      }
    }
    if changed { instances = all }
    let referencedIDs = Set(all.values.compactMap { $0["id"] as? String })
    var configs = configurations
    let previewsToRemove = configs.keys.filter {
      $0.hasPrefix("preview:") && !referencedIDs.contains($0)
    }
    if !previewsToRemove.isEmpty {
      for id in previewsToRemove { configs.removeValue(forKey: id) }
      configurations = configs
    }
  }

  static func nextDate(_ config: [String: Any], after now: Date = Date()) -> Date? {
    let calendar = Calendar.current
    let days = config["weekdays"] as? [Int] ?? []
    let candidates: [Int?] = days.isEmpty ? [nil] : days.map { $0 % 7 + 1 }
    return candidates.compactMap { weekday in
      var components = DateComponents()
      components.hour = config["hour"] as? Int ?? 7
      components.minute = config["minute"] as? Int ?? 30
      components.second = 0
      components.weekday = weekday
      return calendar.nextDate(
        after: now, matching: components, matchingPolicy: .nextTime,
        repeatedTimePolicy: .first, direction: .forward
      )
    }.min()
  }

  /// AlarmKit doesn't launch an arbitrary callback when sound begins. A fired
  /// event is written when an alert is observed or one of its intents executes.
  @discardableResult
  static func markFired(systemID: String) -> [String: Any]? {
    var all = instances
    guard var record = all[systemID] else { return nil }
    if let until = record["ignoreAlertsUntil"] as? NSNumber,
      until.int64Value > now() { return nil }
    let isBase = record["kind"] as? String == "base"
    let lastFire = (record["firedAt"] as? NSNumber)?.doubleValue ?? 0
    let sameDay = Calendar.current.isDate(
      Date(timeIntervalSince1970: lastFire / 1000), inSameDayAs: Date()
    )
    if record["state"] as? String == "ringing" && (!isBase || sameDay) {
      return record
    }
    if isBase || record["occurrenceId"] == nil {
      record["occurrenceId"] = UUID().uuidString
      record["snoozesUsed"] = 0
      // This is an observation time, not a claimed daemon delivery timestamp.
      record["firedAt"] = now()
    }
    record["state"] = "ringing"
    all[systemID] = record
    instances = all
    appendEvent(record, type: "fired")
    return record
  }

  static func finish(systemID: String, type: String) {
    guard var record = instances[systemID] else { return }
    if record["state"] as? String == "dismissed" {
      let timestamp = (record["firedAt"] as? NSNumber)?.doubleValue ?? 0
      let sameDay = Calendar.current.isDateInToday(Date(timeIntervalSince1970: timestamp / 1000))
      if sameDay { return }
    }
    if record["state"] as? String != "ringing" {
      guard let activeRecord = markFired(systemID: systemID) else { return }
      record = activeRecord
    }
    record["state"] = "dismissed"
    record["ignoreAlertsUntil"] = now() + 15_000
    let id = record["id"] as? String ?? ""
    var configs = configurations
    let repeats = !(configs[id]?["weekdays"] as? [Int] ?? []).isEmpty
    if var config = configs[id] {
      if (config["weekdays"] as? [Int] ?? []).isEmpty {
        config["enabled"] = false
        config.removeValue(forKey: "nextAt")
      } else if let next = nextDate(config) {
        config["nextAt"] = Int64(next.timeIntervalSince1970 * 1000)
      }
      if id.hasPrefix("preview:") {
        configs.removeValue(forKey: id)
      } else {
        configs[id] = config
      }
      configurations = configs
    }
    var all = instances
    // Retain only the weekly base. Finished one-off, preview and snooze
    // occurrences cannot leave a chain of native instance records behind.
    for (key, candidate) in all where candidate["id"] as? String == id {
      if repeats && candidate["kind"] as? String == "base" {
        if key == systemID { all[key] = record }
      } else {
        all.removeValue(forKey: key)
      }
    }
    instances = all
    appendEvent(record, type: type)
  }
}

@available(iOS 26.0, *)
struct FiveMoreOpenChallengeIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Открыть задание"
  static var openAppWhenRun: Bool = true
  @Parameter(title: "Будильник") var systemID: String

  init() { systemID = "" }
  init(systemID: String) { self.systemID = systemID }

  func perform() async throws -> some IntentResult {
    await MainActor.run { _ = FiveMoreAlarmStore.markFired(systemID: systemID) }
    // Do not stop here. Dart will call dismiss only after solving the challenge.
    return .result()
  }
}

@available(iOS 26.0, *)
struct FiveMoreSystemStopIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Остановить будильник"
  static var openAppWhenRun: Bool = false
  @Parameter(title: "Будильник") var systemID: String

  init() { systemID = "" }
  init(systemID: String) { self.systemID = systemID }

  func perform() async throws -> some IntentResult {
    // AlarmKit itself handles its Stop action; this intent only records it.
    await MainActor.run {
      if let record = FiveMoreAlarmStore.instances[systemID],
        let until = record["appStopUntil"] as? NSNumber,
        until.int64Value > FiveMoreAlarmStore.now() { return }
      FiveMoreAlarmStore.finish(systemID: systemID, type: "emergency_dismissed")
    }
    return .result()
  }
}

@available(iOS 26.0, *)
@MainActor
private final class FiveMoreAlarmEngine {
  private let manager = AlarmManager.shared
  private var updatesTask: Task<Void, Never>?
  private var mutationInProgress = false

  init() {
    updatesTask = Task { [weak self] in
      guard let self else { return }
      for await alarms in manager.alarmUpdates {
        if Task.isCancelled { return }
        self.observe(alarms)
      }
    }
  }

  deinit { updatesTask?.cancel() }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "status": result(try status())
      case "restoreAlarms": result(["ok": false, "error": "unsupported_permission"])
      case "requestPermissions":
        result(try await requestPermission(args["target"] as? String))
      case "getRingingAlarm": result(try ringingAlarm())
      case "drainEvents": result(FiveMoreAlarmStore.drainEvents())
      case "ackEvents":
        FiveMoreAlarmStore.acknowledgeEvents(args["eventIds"] as? [String] ?? [])
        result(["ok": true])
      case "schedule", "cancel", "snooze", "dismiss", "testAlarm", "cancelTestAlarm":
        guard !mutationInProgress else {
          result(["ok": false, "error": "Подожди завершения предыдущего действия."])
          return
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        switch call.method {
        case "schedule": result(try await schedule(args))
        case "cancel": result(try cancel(args))
        case "snooze": result(try await snooze(args))
        case "dismiss": result(try dismiss(args))
        case "cancelTestAlarm": result(try cancelTestAlarm(args))
        default: result(try await testAlarm(args))
        }
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      result(["ok": false, "error": error.localizedDescription])
    }
  }

  private func requestPermission(_ target: String?) async throws -> [String: Any] {
    guard target == nil || target == "notifications" || target == "exactAlarms" else {
      var response = try status()
      response["ok"] = false
      response["error"] = "settings_unavailable"
      response["message"] = "Эта настройка недоступна через приложение на iOS."
      return response
    }
    if manager.authorizationState == .denied {
      guard let url = URL(string: UIApplication.openSettingsURLString),
        await UIApplication.shared.open(url, options: [:]) else {
        var response = try status()
        response["ok"] = false
        response["error"] = "settings_unavailable"
        return response
      }
    } else {
      _ = try await manager.requestAuthorization()
    }
    // Opening Settings is not proof that authorization was granted. Dart rechecks on resume.
    return try status()
  }

  private func status() throws -> [String: Any] {
    let alarms = try manager.alarms
    observe(alarms)
    let authorized = manager.authorizationState == .authorized
    let activeSystemIDs = Set(alarms.map { $0.id.uuidString })
    if !mutationInProgress {
      FiveMoreAlarmStore.pruneTransientState(liveSystemIDs: activeSystemIDs)
    }
    let instances = FiveMoreAlarmStore.instances
    let configs = FiveMoreAlarmStore.configurations.values.compactMap { saved -> [String: Any]? in
      guard let id = saved["id"] as? String, !id.hasPrefix("preview:") else { return nil }
      var config = saved
      let liveRecords = instances.filter {
        activeSystemIDs.contains($0.key) && $0.value["id"] as? String == id
      }.map { $0.value }
      let snoozeDate = liveRecords.filter { $0["kind"] as? String == "snooze" }
        .compactMap { ($0["nextAt"] as? NSNumber)?.int64Value }.min()
      if let snoozeDate {
        config["nextAt"] = snoozeDate
      } else if !liveRecords.isEmpty, !(config["weekdays"] as? [Int] ?? []).isEmpty,
        let next = FiveMoreAlarmStore.nextDate(config) {
        config["nextAt"] = Int64(next.timeIntervalSince1970 * 1000)
      }
      // Return actual registration separately from the user's desired enabled
      // flag; permission loss must not silently destroy the saved preference.
      config["scheduled"] = !liveRecords.isEmpty
      return config
    }
    var response: [String: Any] = [
      "platform": "ios", "supported": true, "exactAlarms": authorized,
      "notifications": authorized, "fullScreenIntent": authorized,
      "challengeEnforced": false, "scheduledCount": alarms.count,
      "alarms": configs,
    ]
    for (key, record) in instances where activeSystemIDs.contains(key) {
      guard let id = record["id"] as? String, id.hasPrefix("preview:"), id.count > 8,
        ["scheduled", "ringing", "snoozed"].contains(record["state"] as? String ?? ""),
        let config = FiveMoreAlarmStore.configurations[id], config["enabled"] as? Bool == true,
        let source = config["testSourceId"] as? String, !source.isEmpty, !source.hasPrefix("preview:"),
        let started = (config["testStartedAt"] as? NSNumber)?.int64Value,
        let due = (config["testDueAt"] as? NSNumber)?.int64Value,
        started > 0, due >= started else { continue }
      response["activeTest"] = [
        "sourceAlarmId": source, "previewAlarmId": id, "startedAt": started, "dueAt": due,
      ]
      break
    }
    return response
  }

  private func observe(_ alarms: [Alarm]) {
    for alarm in alarms where alarm.state == .alerting {
      FiveMoreAlarmStore.markFired(systemID: alarm.id.uuidString)
    }
  }

  private func ringingAlarm() throws -> [String: Any]? {
    let alarms = try manager.alarms
    observe(alarms)
    for alarm in alarms where alarm.state == .alerting {
      guard let record = FiveMoreAlarmStore.instances[alarm.id.uuidString],
        record["state"] as? String == "ringing",
        let id = record["id"] as? String,
        let config = FiveMoreAlarmStore.configurations[id] else { continue }
      var response = record
      response["alarm"] = config
      return response
    }
    return nil
  }

  private func validate(_ args: [String: Any]) throws -> [String: Any] {
    guard let id = args["id"] as? String, UUID(uuidString: id) != nil,
      let hour = args["hour"] as? Int, (0...23).contains(hour),
      let minute = args["minute"] as? Int, (0...59).contains(minute),
      let days = args["weekdays"] as? [Int], days.allSatisfy({ (1...7).contains($0) }),
      let snooze = args["snoozeMinutes"] as? Int, (1...30).contains(snooze),
      let maximum = args["maxSnoozes"] as? Int, (0...10).contains(maximum)
    else { throw failure("Проверь время, дни недели и настройки переноса.") }
    let kind = args["challengeKind"] ?? "math"
    let difficulty = args["difficulty"] ?? "medium"
    guard let kind = kind as? String,
      ["math", "memory", "stroop", "sequence", "mirror", "captcha", "mixed"].contains(kind),
      let difficulty = difficulty as? String,
      ["easy", "medium", "hard"].contains(difficulty)
    else { throw failure("Проверь вид и сложность задания.") }
    var escalateOnSnooze = false
    if let value = args["escalateOnSnooze"] {
      // NSNumber can bridge 0/1 to Bool; only CFBoolean is a valid opt-in.
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
      else { throw failure("Проверь настройку усложнения после переноса.") }
      escalateOnSnooze = number.boolValue
    }
    var moveSnoozeButton = false
    if let value = args["moveSnoozeButton"] {
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
      else { throw failure("Проверь настройку перемещения кнопки переноса.") }
      moveSnoozeButton = number.boolValue
    }
    return [
      "id": id, "title": String((args["title"] as? String ?? "").prefix(100)),
      "hour": hour, "minute": minute, "weekdays": Array(Set(days)).sorted(),
      "enabled": args["enabled"] as? Bool ?? true, "snoozeMinutes": snooze,
      "maxSnoozes": maximum, "challengeKind": kind, "difficulty": difficulty,
      "escalateOnSnooze": escalateOnSnooze,
      "moveSnoozeButton": moveSnoozeButton,
    ]
  }

  private func configuration(
    _ config: [String: Any], systemID: UUID, schedule: Alarm.Schedule
  ) -> AlarmManager.AlarmConfiguration<FiveMoreAlarmMetadata> {
    let title = (config["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let alert = AlarmPresentation.Alert(
      title: LocalizedStringResource(stringLiteral: title.isEmpty ? "Пора вставать" : title),
      stopButton: AlarmButton(text: "Остановить", textColor: .white, systemImageName: "stop.circle"),
      secondaryButton: AlarmButton(text: "Задание", textColor: .black, systemImageName: "brain"),
      secondaryButtonBehavior: .custom
    )
    let attributes = AlarmAttributes(
      presentation: AlarmPresentation(alert: alert),
      metadata: FiveMoreAlarmMetadata(logicalID: config["id"] as? String ?? ""),
      tintColor: Color(red: 0.95, green: 0.79, blue: 0.42)
    )
    return AlarmManager.AlarmConfiguration(
      schedule: schedule, attributes: attributes,
      stopIntent: FiveMoreSystemStopIntent(systemID: systemID.uuidString),
      secondaryIntent: FiveMoreOpenChallengeIntent(systemID: systemID.uuidString),
      sound: .default
    )
  }

  private func schedule(_ args: [String: Any]) async throws -> [String: Any] {
    var config = try validate(args)
    let id = config["id"] as! String
    try requireIdle(id)
    if config["enabled"] as? Bool == false {
      _ = try cancel(["id": id])
      var configs = FiveMoreAlarmStore.configurations
      configs[id] = config
      FiveMoreAlarmStore.configurations = configs
      return ["ok": true, "alarm": config]
    }
    guard manager.authorizationState == .authorized else {
      throw failure("Разреши будильники в настройках iOS.")
    }
    let days = config["weekdays"] as! [Int]
    let weekdays: [Locale.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    let relative = Alarm.Schedule.Relative(
      time: .init(hour: config["hour"] as! Int, minute: config["minute"] as! Int),
      repeats: days.isEmpty ? .never : .weekly(days.map { weekdays[$0 - 1] })
    )
    guard let next = FiveMoreAlarmStore.nextDate(config) else {
      throw failure("Не удалось определить следующее время будильника.")
    }
    let nextAt = Int64(next.timeIntervalSince1970 * 1000)
    config["nextAt"] = nextAt
    let previousInstances = FiveMoreAlarmStore.instances.filter { $0.value["id"] as? String == id }
    let previousSystemIDs = Set(previousInstances.keys)
    let previousAlarms = try manager.alarms.filter { previousSystemIDs.contains($0.id.uuidString) }
    let uuid = UUID()
    // Schedule first: a failed replacement must not erase the saved config.
    _ = try await manager.schedule(id: uuid, configuration: configuration(config, systemID: uuid, schedule: .relative(relative)))
    do {
      for old in previousAlarms { try manager.cancel(id: old.id) }
    } catch {
      try? manager.cancel(id: uuid)
      throw error
    }
    var configs = FiveMoreAlarmStore.configurations
    configs[id] = config
    FiveMoreAlarmStore.configurations = configs
    var instances = FiveMoreAlarmStore.instances
    for key in previousSystemIDs { instances.removeValue(forKey: key) }
    instances[uuid.uuidString] = [
      "id": id, "kind": "base", "state": "scheduled", "snoozesUsed": 0,
      "nextAt": nextAt,
    ]
    FiveMoreAlarmStore.instances = instances
    return ["ok": true, "alarm": config, "nextAt": nextAt]
  }

  private func cancel(_ args: [String: Any]) throws -> [String: Any] {
    guard let id = args["id"] as? String else { throw failure("Не указан будильник.") }
    try requireIdle(id)
    let existing = try manager.alarms
    var instances = FiveMoreAlarmStore.instances
    let selected = instances.filter { $0.value["id"] as? String == id }
    for (key, _) in selected {
      guard let uuid = UUID(uuidString: key) else { continue }
      if existing.contains(where: { $0.id == uuid }) { try manager.cancel(id: uuid) }
      instances.removeValue(forKey: key)
    }
    FiveMoreAlarmStore.instances = instances
    var configs = FiveMoreAlarmStore.configurations
    var config = configs[id] ?? ["id": id]
    config["enabled"] = false
    config.removeValue(forKey: "nextAt")
    configs[id] = config
    FiveMoreAlarmStore.configurations = configs
    return ["ok": true, "alarm": config]
  }

  private func active(_ id: String) throws -> (UUID, [String: Any], [String: Any]) {
    let alarms = try manager.alarms
    observe(alarms)
    for alarm in alarms where alarm.state == .alerting {
      if let record = FiveMoreAlarmStore.instances[alarm.id.uuidString],
        record["state"] as? String == "ringing",
        record["id"] as? String == id,
        let config = FiveMoreAlarmStore.configurations[id] {
        return (alarm.id, record, config)
      }
    }
    throw failure("Этот будильник сейчас не звонит.")
  }

  private func snooze(_ args: [String: Any]) async throws -> [String: Any] {
    guard let id = args["id"] as? String else { throw failure("Не указан будильник.") }
    let (currentID, record, config) = try active(id)
    let used = record["snoozesUsed"] as? Int ?? 0
    let maximum = config["maxSnoozes"] as? Int ?? 0
    guard used < maximum else { throw failure("Переносы закончились. Пора выполнить задание.") }
    let next = Date().addingTimeInterval(TimeInterval((config["snoozeMinutes"] as? Int ?? 5) * 60))
    let nextAt = Int64(next.timeIntervalSince1970 * 1000)
    let uuid = UUID()
    // A separate fixed alarm leaves the original weekly schedule intact.
    _ = try await manager.schedule(id: uuid, configuration: configuration(config, systemID: uuid, schedule: .fixed(next)))
    let stopGuard = FiveMoreAlarmStore.now() + 15_000
    FiveMoreAlarmStore.suppressSystemStop(currentID.uuidString, until: stopGuard)
    do { try manager.stop(id: currentID) }
    catch {
      FiveMoreAlarmStore.suppressSystemStop(currentID.uuidString, until: nil)
      try? manager.cancel(id: uuid)
      throw error
    }
    var instances = FiveMoreAlarmStore.instances
    var previous = record
    previous["state"] = "snoozed"
    previous["ignoreAlertsUntil"] = FiveMoreAlarmStore.now() + 15_000
    previous["appStopUntil"] = stopGuard
    if record["kind"] as? String == "base" {
      instances[currentID.uuidString] = previous
    } else {
      instances.removeValue(forKey: currentID.uuidString)
    }
    var nextRecord = record
    nextRecord["kind"] = "snooze"
    nextRecord["state"] = "scheduled"
    nextRecord["snoozesUsed"] = used + 1
    nextRecord["nextAt"] = nextAt
    instances[uuid.uuidString] = nextRecord
    FiveMoreAlarmStore.instances = instances
    FiveMoreAlarmStore.appendEvent(nextRecord, type: "snoozed", nextAt: nextAt)
    return ["ok": true, "alarm": config, "snoozesUsed": used + 1, "nextAt": nextAt]
  }

  private func dismiss(_ args: [String: Any]) throws -> [String: Any] {
    guard let id = args["id"] as? String else { throw failure("Не указан будильник.") }
    let (uuid, record, config) = try active(id)
    FiveMoreAlarmStore.suppressSystemStop(uuid.uuidString, until: FiveMoreAlarmStore.now() + 15_000)
    do { try manager.stop(id: uuid) }
    catch {
      FiveMoreAlarmStore.suppressSystemStop(uuid.uuidString, until: nil)
      throw error
    }
    FiveMoreAlarmStore.finish(
      systemID: uuid.uuidString,
      type: args["emergency"] as? Bool == true ? "emergency_dismissed" : "dismissed"
    )
    return [
      "ok": true, "alarm": FiveMoreAlarmStore.configurations[id] ?? config,
      "snoozesUsed": record["snoozesUsed"] as? Int ?? 0,
    ]
  }

  private func testAlarm(_ args: [String: Any]) async throws -> [String: Any] {
    guard let delay = testDelaySeconds(args["delaySeconds"]) else {
      return ["ok": false, "error": "invalid_test_delay"]
    }
    guard let id = args["id"] as? String,
      !id.hasPrefix("preview:"),
      var config = FiveMoreAlarmStore.configurations[id] else {
      throw failure("Сначала сохрани будильник.")
    }
    try requireIdle(id)
    guard manager.authorizationState == .authorized else {
      throw failure("Разреши будильники в настройках iOS.")
    }
    let registered = try manager.alarms
    if registered.contains(where: {
      (FiveMoreAlarmStore.instances[$0.id.uuidString]?["id"] as? String)?.hasPrefix("preview:") == true
    }) {
      return ["ok": false, "error": "test_alarm_active"]
    }
    let previewID = "preview:\(UUID().uuidString)"
    config["id"] = previewID
    config["weekdays"] = [Int]()
    config["enabled"] = true
    config["title"] = "Пробный подъём"
    let startedAt = FiveMoreAlarmStore.now()
    let next = Date(timeIntervalSince1970: Double(startedAt) / 1000).addingTimeInterval(TimeInterval(delay))
    let nextAt = Int64(next.timeIntervalSince1970 * 1000)
    config["nextAt"] = nextAt
    config["testSourceId"] = id
    config["testStartedAt"] = startedAt
    config["testDueAt"] = nextAt
    let uuid = UUID()
    var configs = FiveMoreAlarmStore.configurations
    configs[previewID] = config
    var instances = FiveMoreAlarmStore.instances
    instances[uuid.uuidString] = [
      "id": previewID, "kind": "preview", "state": "scheduled", "snoozesUsed": 0,
      "nextAt": nextAt,
    ]
    // Save both pieces together before suspension: a process exit after AlarmKit
    // accepts the schedule must still leave the preview identity recoverable.
    var root = FiveMoreAlarmStore.data
    root["configurations"] = configs
    root["instances"] = instances
    FiveMoreAlarmStore.data = root
    do {
      _ = try await manager.schedule(id: uuid, configuration: configuration(config, systemID: uuid, schedule: .fixed(next)))
    } catch {
      var rollback = FiveMoreAlarmStore.data
      var savedConfigs = FiveMoreAlarmStore.configurations
      var savedInstances = FiveMoreAlarmStore.instances
      savedConfigs.removeValue(forKey: previewID)
      savedInstances.removeValue(forKey: uuid.uuidString)
      rollback["configurations"] = savedConfigs
      rollback["instances"] = savedInstances
      FiveMoreAlarmStore.data = rollback
      throw error
    }
    return ["ok": true, "alarm": config, "nextAt": nextAt]
  }

  private func testDelaySeconds(_ value: Any?) -> Int? {
    guard let value else { return 5 }
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
    let seconds = number.int64Value
    guard (5...60).contains(seconds), number.doubleValue == Double(seconds) else { return nil }
    return Int(seconds)
  }

  /// Preview-only and idempotent. No ordinary configuration is disabled or rewritten.
  private func cancelTestAlarm(_ args: [String: Any]) throws -> [String: Any] {
    guard let id = args["id"] as? String, id.hasPrefix("preview:"), id.count > 8 else {
      return ["ok": false, "error": "invalid_test_id"]
    }
    let existing = try manager.alarms
    observe(existing)
    let selected = FiveMoreAlarmStore.instances.filter { $0.value["id"] as? String == id }
    for (key, _) in selected {
      guard let uuid = UUID(uuidString: key),
        let alarm = existing.first(where: { $0.id == uuid }) else { continue }
      if alarm.state == .alerting {
        FiveMoreAlarmStore.suppressSystemStop(key, until: FiveMoreAlarmStore.now() + 15_000)
        do { try manager.stop(id: uuid) }
        catch {
          FiveMoreAlarmStore.suppressSystemStop(key, until: nil)
          throw error
        }
        FiveMoreAlarmStore.finish(systemID: key, type: "emergency_dismissed")
      } else {
        try manager.cancel(id: uuid)
      }
    }
    var instances = FiveMoreAlarmStore.instances
    for key in selected.keys { instances.removeValue(forKey: key) }
    FiveMoreAlarmStore.instances = instances
    var configs = FiveMoreAlarmStore.configurations
    configs.removeValue(forKey: id)
    FiveMoreAlarmStore.configurations = configs
    return ["ok": true]
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "five_more.alarm", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func requireIdle(_ id: String) throws {
    let alarms = try manager.alarms
    for alarm in alarms {
      guard let record = FiveMoreAlarmStore.instances[alarm.id.uuidString],
        record["id"] as? String == id else { continue }
      if alarm.state == .alerting || record["kind"] as? String == "snooze" {
        throw failure("Сначала заверши текущий подъём или перенос.")
      }
    }
  }
}
#endif
