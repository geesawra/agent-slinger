import Foundation
import Observation
import XCTest

@testable import Oesap

@MainActor
final class FeatureStateTests: XCTestCase {
  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: "selectedProjectID")
    UserDefaults.standard.removeObject(forKey: "selectedThreadID")
  }

  func testBundledATSLimitsPlaintextIPExceptionToTailscaleRange() throws {
    let ats = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
    XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
    let exceptions = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
    XCTAssertEqual(Set(exceptions.keys), ["100.64.0.0/10"])
    let tailscale = try XCTUnwrap(exceptions["100.64.0.0/10"])
    XCTAssertEqual(tailscale["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true)
    XCTAssertNil(tailscale["NSExceptionMinimumTLSVersion"])
    XCTAssertNil(tailscale["NSExceptionRequiresForwardSecrecy"])
    XCTAssertTrue(
      RemoteConnection.empty.usesTLS, "ATS permission must not change the user's TLS choice.")
  }

  private func notificationURL(
    agent: String = "thread-B", workspace: String = "workspace-B",
    server: String = "fixture-host", anchor: String = ""
  ) -> URL {
    URL(
      string:
        "agentslinger://open?v=1&serverId=\(server)&workspaceId=\(workspace)&agentId=\(agent)\(anchor)"
    )!
  }

  func testNotificationColdLaunchSelectsSavedHostAndAuthoritativeProject() async {
    let service = FakeRemoteService()
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "saved", name: "Host", subtitle: "", serverID: "fixture-host")
        ],
        instanceServices: ["saved": service]))
    await model.openNotificationURL(notificationURL())
    XCTAssertEqual(model.activeInstanceID, "saved")
    XCTAssertEqual(model.selectedProjectID, "B")
    XCTAssertEqual(model.selectedThreadID, "thread-B")
    XCTAssertEqual(model.openLinkNavigation?.route, .chat("thread-B"))
    XCTAssertNil(model.pendingOpenIntent)
    await model.disconnect()
  }

  func testNotificationUnknownHostRetainsIntentUntilManualConnection() async {
    let service = FakeRemoteService()
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.openNotificationURL(notificationURL())
    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertNotNil(model.pendingOpenIntent)
    XCTAssertEqual(model.openLinkNavigation?.route, .notificationConnection)
    XCTAssertNil(model.openLinkNotice)
    await model.connect(.empty)
    for _ in 0..<100 where model.selectedThreadID != "thread-B" { await Task.yield() }
    XCTAssertEqual(model.selectedThreadID, "thread-B")
    XCTAssertNil(model.pendingOpenIntent)
    await model.disconnect()
  }

  func testDismissedUnknownServerPromptKeepsIntentWithoutPresentingAgain() async {
    let other = FakeRemoteService(serverIDValue: "other-host")
    let target = FakeRemoteService()
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [other, target]))
    await model.openNotificationURL(notificationURL())
    model.dismissNotificationConnectionPrompt()
    XCTAssertNotNil(model.pendingOpenIntent)
    XCTAssertNil(model.openLinkNavigation)

    await model.connect(.empty)
    for _ in 0..<100 { await Task.yield() }
    XCTAssertNil(model.openLinkNavigation)
    XCTAssertNil(model.openLinkNotice)
    XCTAssertNotNil(model.pendingOpenIntent)

    await model.connect(.empty)
    let opened = await eventually { model.selectedThreadID == "thread-B" }
    XCTAssertTrue(opened)
    XCTAssertNil(model.pendingOpenIntent)
    await model.disconnect()
  }

  func testOpeningLinkAgainShowsDismissedUnknownServerPrompt() async {
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: []))
    await model.openNotificationURL(notificationURL())
    model.dismissNotificationConnectionPrompt()
    await model.openNotificationURL(notificationURL())
    XCTAssertEqual(model.openLinkNavigation?.route, .notificationConnection)
    XCTAssertNotNil(model.pendingOpenIntent)
  }

  func testNotificationRejectsSavedHostHandshakeMismatch() async {
    let service = FakeRemoteService(serverIDValue: "impostor")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "saved", name: "Host", subtitle: "", serverID: "fixture-host")
        ],
        instanceServices: ["saved": service]))
    await model.openNotificationURL(notificationURL())
    XCTAssertNil(model.selectedThreadID)
    XCTAssertTrue(model.openLinkNotice?.contains("identity") == true)
    XCTAssertNotNil(model.pendingOpenIntent)
    await model.disconnect()
  }

  func testNotificationWorkspaceMismatchDoesNotTreatWorkspaceAsProject() async {
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [FakeRemoteService()]))
    await model.start()
    await model.connect(.empty)
    await model.openNotificationURL(notificationURL(workspace: "B"))
    XCTAssertNil(model.selectedThreadID)
    XCTAssertEqual(model.openLinkNavigation?.route, .agentOverview)
    XCTAssertNotNil(model.openLinkNotice)
    await model.disconnect()
  }

  func testNotificationOlderMessageAndResolvedPermissionAnchors() async {
    let old = RemoteMessage(id: "older", author: .agent, text: "Earlier", timestamp: nil)
    let service = FakeRemoteService(olderMessages: [old])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.start()
    await model.connect(.empty)
    await model.openNotificationURL(notificationURL(anchor: "&messageId=older"))
    for _ in 0..<100 where model.openLinkHighlight == nil { await Task.yield() }
    XCTAssertEqual(model.openLinkHighlight?.target, .message("older"))
    XCTAssertTrue(model.messages.contains { $0.id == "older" })
    await model.openNotificationURL(notificationURL(anchor: "&permissionId=resolved"))
    XCTAssertNil(model.openLinkHighlight)
    XCTAssertTrue(model.openLinkNotice?.contains("no longer pending") == true)
    await model.disconnect()
  }

  func testNewNotificationSupersedesInFlightAgentLookup() async {
    let gate = TestGate()
    let service = FakeRemoteService(openAgentGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.start()
    await model.connect(.empty)
    let first = Task { await model.openNotificationURL(notificationURL()) }
    await gate.waitUntilEntered()
    await model.openNotificationURL(notificationURL(agent: "thread-A", workspace: "workspace-A"))
    await gate.open()
    await first.value
    for _ in 0..<100 where model.selectedThreadID != "thread-A" { await Task.yield() }
    XCTAssertEqual(model.selectedThreadID, "thread-A")
    XCTAssertEqual(model.openLinkNavigation?.route, .chat("thread-A"))
    await model.disconnect()
  }

  func testNotificationSelectsSecondPendingPermissionWithoutAnsweringIt() async {
    let permissions = ["first", "second"].map {
      RemotePermission(
        id: $0, agentID: "thread-B", title: $0, detail: nil,
        kind: "permission", supportsSimpleDecision: true, allowActionID: "allow",
        denyActionID: "deny", allowLabel: nil, denyLabel: nil)
    }
    let service = FakeRemoteService(openPermissions: permissions)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.start()
    await model.connect(.empty)
    await model.openNotificationURL(notificationURL(anchor: "&permissionId=second"))
    for _ in 0..<100 where model.openLinkHighlight == nil { await Task.yield() }
    XCTAssertEqual(model.pendingPermission(for: "thread-B")?.id, "second")
    XCTAssertEqual(model.selectedPermission?.id, "second")
    let answers = await service.permissionAnswerCount()
    XCTAssertEqual(answers, 0)
    await model.disconnect()
    XCTAssertNil(model.openLinkHighlight)
  }

  func testNotificationMissingAnchorStopsAfterFivePages() async {
    let service = FakeRemoteService(endlessOlderPages: true)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.start()
    await model.connect(.empty)
    await model.openNotificationURL(notificationURL(anchor: "&messageId=missing"))
    for _ in 0..<100 where model.openLinkNotice == nil { await Task.yield() }
    let pages = await service.olderPageCallCount()
    XCTAssertEqual(pages, 5)
    XCTAssertNil(model.openLinkHighlight)
    XCTAssertEqual(model.selectedThreadID, "thread-B")
    XCTAssertTrue(model.openLinkNotice?.contains("not found") == true)
    await model.disconnect()
  }

  func testManualSelectionSupersedesInFlightNotificationLookup() async {
    let gate = TestGate()
    let service = FakeRemoteService(openAgentGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.start()
    await model.connect(.empty)
    let opening = Task { await model.openNotificationURL(notificationURL()) }
    await gate.waitUntilEntered()
    model.selectThread("thread-A")
    await gate.open()
    await opening.value
    XCTAssertEqual(model.selectedThreadID, "thread-A")
    XCTAssertNil(model.openLinkNavigation)
    await model.disconnect()
  }

  func testWarmNotificationSwitchesToMatchingSavedHost() async {
    let first = FakeRemoteService(serverIDValue: "other-host")
    let second = FakeRemoteService()
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "other", name: "Other", subtitle: "", serverID: "other-host"),
          .init(id: "target", name: "Target", subtitle: "", serverID: "fixture-host"),
        ], activeInstanceID: "other", instanceServices: ["other": first, "target": second]))
    await model.start()
    XCTAssertEqual(model.activeInstanceID, "other")
    await model.openNotificationURL(notificationURL())
    XCTAssertEqual(model.activeInstanceID, "target")
    XCTAssertEqual(model.selectedThreadID, "thread-B")
    await model.disconnect()
  }

  func testWarmNotificationRefreshesMissingProjectOnce() async {
    let first = RemoteProject(id: "A", name: "A", subtitle: nil)
    let created = RemoteProject(id: "B", name: "B", subtitle: nil)
    let service = FakeRemoteService(projects: [first], projectsAfterFirstCall: [first, created])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.start()
    await model.connect(.empty)
    XCTAssertEqual(model.projects.map(\.id), ["A"])
    await model.openNotificationURL(notificationURL())
    XCTAssertEqual(model.selectedProjectID, "B")
    XCTAssertEqual(model.selectedThreadID, "thread-B")
    let requests = await service.projectCallCount()
    XCTAssertEqual(requests, 2)
    await model.disconnect()
  }

  func testDraftChangeInvalidatesViewObservation() async {
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: []))
    let changed = expectation(description: "A view reading the draft is invalidated")
    withObservationTracking {
      _ = model.draft(for: "thread-A")
    } onChange: {
      changed.fulfill()
    }

    model.setDraft("ready to send", for: "thread-A")
    await fulfillment(of: [changed], timeout: 1)
    XCTAssertEqual(model.draft(for: "thread-A"), "ready to send")
  }

  func testSessionSettingsApplyReadsBackHostNormalizedValues() async {
    let service = FakeRemoteService(
      initialSettings: sessionSettingsFixture(), normalizedThinkingOptionID: "high")
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    await model.openSessionDetails(threadID: "thread-A")
    XCTAssertEqual(model.sessionSettings?.modelID, "model-one")
    XCTAssertEqual(model.sessionDraftThinkingOptionID, "medium")

    model.chooseSessionModel("model-two")
    XCTAssertNil(model.sessionDraftThinkingOptionID)
    model.chooseSessionThinkingOption("max")
    model.chooseSessionMode("full-access")
    XCTAssertTrue(model.sessionSettingsHaveChanges)
    await model.applySessionSettings(threadID: "thread-A")

    let applyCalls = await service.settingsApplyCallCount()
    let settingsCalls = await service.settingsCallCount()
    XCTAssertEqual(applyCalls, 1)
    XCTAssertEqual(settingsCalls, 3)
    XCTAssertEqual(model.sessionSettings?.modelID, "model-two")
    XCTAssertEqual(model.sessionSettings?.thinkingOptionID, "high")
    XCTAssertEqual(model.sessionSettings?.currentModeID, "full-access")
    XCTAssertEqual(model.sessionDraftThinkingOptionID, "high")
    XCTAssertEqual(model.sessionDraftModeID, "full-access")
    XCTAssertFalse(model.sessionSettingsHaveChanges)
    XCTAssertEqual(model.sessionDetailsNotice, "Host accepted the settings.")
    model.chooseSessionThinkingOption("max")
    await model.applySessionSettings(threadID: "thread-A")
    let thinkingCalls = await service.thinkingApplyCallCount()
    let unchangedFullCalls = await service.settingsApplyCallCount()
    XCTAssertEqual(thinkingCalls, 1)
    XCTAssertEqual(unchangedFullCalls, 1)
    XCTAssertEqual(model.sessionSettings?.modelID, "model-two")
    await model.disconnect()
  }

  func testSessionSettingsPartialRejectionShowsAuthoritativeValueAndPendingChoice() async {
    let service = FakeRemoteService(
      initialSettings: sessionSettingsFixture(),
      settingsApplyError: RemoteServiceError.unavailable("Effort was refused"))
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    await model.openSessionDetails(threadID: "thread-A")
    model.chooseSessionModel("model-two")
    model.chooseSessionThinkingOption("max")
    model.chooseSessionMode("full-access")

    await model.applySessionSettings(threadID: "thread-A")

    XCTAssertEqual(model.sessionSettings?.modelID, "model-two")
    XCTAssertEqual(model.sessionSettings?.thinkingOptionID, "medium")
    XCTAssertEqual(model.sessionSettings?.currentModeID, "full-access")
    XCTAssertEqual(model.sessionDraftThinkingOptionID, "max")
    XCTAssertTrue(model.sessionSettingsHaveChanges)
    XCTAssertTrue(model.sessionDetailsError?.contains("Effort was refused") == true)
    await model.disconnect()
  }

  func testSessionPermissionModeOnlyApplyLeavesUnknownModelUntouched() async {
    var settings = sessionSettingsFixture()
    settings.modelID = "unlisted-host-model"
    settings.models = []
    let service = FakeRemoteService(initialSettings: settings)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    await model.openSessionDetails(threadID: "thread-A")
    model.chooseSessionMode("full-access")
    XCTAssertTrue(model.canApplySessionSettings)

    await model.applySessionSettings(threadID: "thread-A")

    let modeCalls = await service.modeApplyCallCount()
    let fullSettingsCalls = await service.settingsApplyCallCount()
    XCTAssertEqual(modeCalls, 1)
    XCTAssertEqual(fullSettingsCalls, 0)
    XCTAssertEqual(model.sessionSettings?.modelID, "unlisted-host-model")
    XCTAssertEqual(model.sessionSettings?.currentModeID, "full-access")
    XCTAssertFalse(model.sessionSettingsHaveChanges)
    await model.disconnect()
  }

  func testOldSessionSettingsLoadCannotReplaceNewSelection() async {
    let gate = TestGate()
    let service = FakeRemoteService(initialSettings: sessionSettingsFixture(), settingsGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let oldLoad = Task { await model.openSessionDetails(threadID: "thread-A") }
    await gate.waitUntilEntered()

    model.selectThread("thread-B")
    await model.openSessionDetails(threadID: "thread-B")
    XCTAssertEqual(model.sessionSettings?.agentID, "thread-B")
    await gate.open()
    await oldLoad.value
    XCTAssertEqual(model.sessionSettings?.agentID, "thread-B")
    await model.disconnect()
    XCTAssertNil(model.sessionSettings)
  }

  func testOldSessionSettingsApplyCannotReplaceNewSelection() async {
    let gate = TestGate()
    let service = FakeRemoteService(
      initialSettings: sessionSettingsFixture(), settingsApplyGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    await model.openSessionDetails(threadID: "thread-A")
    model.chooseSessionModel("model-two")
    let oldApply = Task { await model.applySessionSettings(threadID: "thread-A") }
    await gate.waitUntilEntered()

    model.selectThread("thread-B")
    await model.openSessionDetails(threadID: "thread-B")
    XCTAssertEqual(model.sessionSettings?.agentID, "thread-B")
    XCTAssertFalse(model.sessionDetailsLoading)
    await gate.open()
    await oldApply.value
    XCTAssertEqual(model.sessionSettings?.agentID, "thread-B")
    XCTAssertEqual(model.sessionDraftModelID, "model-one")
    XCTAssertNil(model.sessionDetailsError)
    model.chooseSessionModel("model-two")
    XCTAssertTrue(model.canApplySessionSettings)
    await model.disconnect()
  }

  func testImageOnlySendCapturesImagesAndClearsOnlySubmittedImages() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(sendGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let first = RemoteDraftImage(id: "first", data: Data([1]), mimeType: "image/png")
    let second = RemoteDraftImage(id: "second", data: Data([2]), mimeType: "image/jpeg")
    XCTAssertTrue(model.addDraftImage(first, for: "thread-A"))
    let sending = Task { await model.send(threadID: "thread-A", text: "") }
    await gate.waitUntilEntered()
    XCTAssertTrue(model.addDraftImage(second, for: "thread-A"))
    await gate.open()
    let accepted = await sending.value
    XCTAssertTrue(accepted)
    XCTAssertEqual(model.draftImages(for: "thread-A"), [second])
    let sent = await service.sentMessages()
    XCTAssertEqual(sent.first?.text, "")
    XCTAssertEqual(sent.first?.images, [first])
    await model.disconnect()
  }

  func testImageRetryReplaysOriginalBytesDespiteDraftEdit() async throws {
    let service = FakeRemoteService(failSendCalls: [1])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let original = RemoteDraftImage(id: "original", data: Data([1]), mimeType: "image/png")
    let replacement = RemoteDraftImage(id: "new", data: Data([2]), mimeType: "image/png")
    model.setDraft("First", for: "thread-A")
    XCTAssertTrue(model.addDraftImage(original, for: "thread-A"))
    let first = await model.send(threadID: "thread-A", text: "First")
    XCTAssertFalse(first)
    model.setDraft("Edited", for: "thread-A")
    XCTAssertTrue(model.setDraftImages([replacement], for: "thread-A"))
    let retried = await model.retryAgentMessage(threadID: "thread-A")
    XCTAssertTrue(retried)
    let sent = await service.sentMessages()
    XCTAssertEqual(sent.count, 2)
    XCTAssertEqual(sent[0], sent[1])
    XCTAssertEqual(sent[0].images, [original])
    XCTAssertEqual(model.draft(for: "thread-A"), "Edited")
    XCTAssertEqual(model.draftImages(for: "thread-A"), [replacement])
    await model.disconnect()
  }

  func testSavedInstancesCanBeSelectedAndDisconnectRemovesOnlyTheActiveOne() async {
    let first = FakeRemoteService(
      projects: [.init(id: "project-a", name: "Project A", subtitle: nil)],
      serverIDValue: "host-a")
    let second = FakeRemoteService(
      projects: [.init(id: "project-b", name: "Project B", subtitle: nil)],
      serverIDValue: "host-b")
    let instances = [
      SavedPaseoInstance(id: "host-a", name: "Work", subtitle: "work.example"),
      SavedPaseoInstance(id: "host-b", name: "Personal", subtitle: "personal.example"),
    ]
    let factory = FakeConnectionFactory(
      connectServices: [], initiallySavedInstances: instances,
      activeInstanceID: "host-a", instanceServices: ["host-a": first, "host-b": second])
    let model = OesapModel(connectionFactory: factory)
    await model.refreshSavedInstances()

    XCTAssertTrue(model.hasSavedConnection)
    XCTAssertEqual(model.savedInstances, instances)
    let selectedFirst = await model.selectSavedInstance("host-a")
    XCTAssertTrue(selectedFirst)
    XCTAssertEqual(model.activeInstanceID, "host-a")
    XCTAssertEqual(model.projects.map(\.id), ["project-a"])

    let selectedSecond = await model.selectSavedInstance("host-b")
    XCTAssertTrue(selectedSecond)
    XCTAssertEqual(model.activeInstanceID, "host-b")
    XCTAssertEqual(model.projects.map(\.id), ["project-b"])
    let firstClosed = await first.isClosed()
    XCTAssertTrue(firstClosed)

    await model.disconnect()
    XCTAssertEqual(model.savedInstances.map(\.id), ["host-a"])
    XCTAssertTrue(model.hasSavedConnection)
    XCTAssertNil(model.activeInstanceID)
    let selectedAgain = await model.selectSavedInstance("host-a")
    XCTAssertTrue(selectedAgain)
    XCTAssertEqual(model.projects.map(\.id), ["project-a"])
    await model.disconnect()
  }

  func testSwitchingInstancesReleasesPendingSettingsMutation() async {
    let oldHostApplyGate = TestGate()
    let first = FakeRemoteService(
      serverIDValue: "host-a", initialSettings: sessionSettingsFixture(),
      settingsApplyGate: oldHostApplyGate)
    let second = FakeRemoteService(
      serverIDValue: "host-b", initialSettings: sessionSettingsFixture())
    let factory = FakeConnectionFactory(
      connectServices: [],
      initiallySavedInstances: [
        SavedPaseoInstance(id: "host-a", name: "Work", subtitle: "work.example"),
        SavedPaseoInstance(id: "host-b", name: "Personal", subtitle: "personal.example"),
      ],
      activeInstanceID: "host-a", instanceServices: ["host-a": first, "host-b": second])
    let model = OesapModel(connectionFactory: factory)
    await model.refreshSavedInstances()
    let selectedFirst = await model.selectSavedInstance("host-a")
    XCTAssertTrue(selectedFirst)
    model.selectThread("thread-A")
    await model.openSessionDetails(threadID: "thread-A")
    model.chooseSessionModel("model-two")
    let oldApply = Task { await model.applySessionSettings(threadID: "thread-A") }
    await oldHostApplyGate.waitUntilEntered()

    let selectedSecond = await model.selectSavedInstance("host-b")
    XCTAssertTrue(selectedSecond)
    model.selectThread("thread-A")
    await model.openSessionDetails(threadID: "thread-A")
    model.chooseSessionModel("model-two")
    XCTAssertTrue(model.canApplySessionSettings)
    await model.applySessionSettings(threadID: "thread-A")
    XCTAssertEqual(model.sessionSettings?.modelID, "model-two")

    await oldHostApplyGate.open()
    await oldApply.value
    XCTAssertEqual(model.sessionSettings?.modelID, "model-two")
    let secondApplyCalls = await second.settingsApplyCallCount()
    XCTAssertEqual(secondApplyCalls, 1)
    await model.disconnect()
  }

  func testInstanceSwitchClearsHostStateAndRejectsLateWorkspaceResults() async throws {
    let projectGate = TestGate()
    let first = FakeRemoteService(
      projects: [.init(id: "project-a", name: "Project A", subtitle: nil)],
      projectGate: projectGate, projectGateAtCall: 2,
      historyMessages: [
        RemoteMessage(id: "old-message", author: .agent, text: "Host A", timestamp: nil)
      ], serverIDValue: "host-a")
    let second = FakeRemoteService(
      projects: [.init(id: "project-b", name: "Project B", subtitle: nil)],
      serverIDValue: "host-b")
    let factory = FakeConnectionFactory(
      connectServices: [],
      initiallySavedInstances: [
        SavedPaseoInstance(id: "host-a", name: "Work", subtitle: "work.example"),
        SavedPaseoInstance(id: "host-b", name: "Personal", subtitle: "personal.example"),
      ],
      activeInstanceID: "host-a", instanceServices: ["host-a": first, "host-b": second])
    let model = OesapModel(connectionFactory: factory)
    await model.refreshSavedInstances()
    let selectedFirst = await model.selectSavedInstance("host-a")
    XCTAssertTrue(selectedFirst)
    model.selectThread("thread-project-a")
    model.setDraft("draft for host A", for: "thread-project-a")
    let timeline = Task { await model.watchTimeline(threadID: "thread-project-a") }
    let historyLoaded = await eventually { model.messages.first?.text == "Host A" }
    XCTAssertTrue(historyLoaded)

    let lateRefresh = Task { await model.refreshWorkspace() }
    await projectGate.waitUntilEntered()
    let selectedSecond = await model.selectSavedInstance("host-b")
    XCTAssertTrue(selectedSecond)
    await projectGate.open()
    await lateRefresh.value
    await timeline.value

    XCTAssertEqual(model.activeInstanceID, "host-b")
    XCTAssertEqual(model.projects.map(\.id), ["project-b"])
    XCTAssertNil(model.selectedThreadID)
    XCTAssertTrue(model.messages.isEmpty)
    XCTAssertEqual(model.draft(for: "thread-project-a"), "")
    let firstClosed = await first.isClosed()
    XCTAssertTrue(firstClosed)

    await model.removeSavedInstance("host-a")
    XCTAssertEqual(model.projects.map(\.id), ["project-b"])
    XCTAssertEqual(model.activeInstanceID, "host-b")
    await model.disconnect()
  }

  func testFailedInstanceSwitchKeepsTargetSelectedAndClearsPreviousHost() async {
    let first = FakeRemoteService(
      projects: [.init(id: "project-a", name: "Project A", subtitle: nil)],
      serverIDValue: "host-a")
    let factory = FakeConnectionFactory(
      connectServices: [],
      initiallySavedInstances: [
        SavedPaseoInstance(id: "host-a", name: "Work", subtitle: "work.example"),
        SavedPaseoInstance(id: "host-b", name: "Personal", subtitle: "personal.example"),
      ],
      activeInstanceID: "host-a", instanceServices: ["host-a": first])
    let model = OesapModel(connectionFactory: factory)
    await model.refreshSavedInstances()
    let selectedFirst = await model.selectSavedInstance("host-a")
    XCTAssertTrue(selectedFirst)
    model.setDraft("private host A draft", for: "thread-project-a")

    let selectedMissingTarget = await model.selectSavedInstance("host-b")

    XCTAssertFalse(selectedMissingTarget)
    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertEqual(model.activeInstanceID, "host-b")
    XCTAssertTrue(model.hasSavedConnection)
    XCTAssertTrue(model.projects.isEmpty)
    XCTAssertTrue(model.messages.isEmpty)
    XCTAssertEqual(model.draft(for: "thread-project-a"), "")
    XCTAssertNotNil(model.instanceError)
    let firstClosed = await first.isClosed()
    XCTAssertTrue(firstClosed)
  }

  func testLateProjectRefreshCannotResurrectDisconnectedWorkspace() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(projectGate: gate)
    let factory = FakeConnectionFactory(connectServices: [service])
    let model = OesapModel(connectionFactory: factory)
    await model.connect(.empty)
    XCTAssertEqual(model.projects.map(\.id), ["A", "B"])

    let refresh = Task { await model.refreshWorkspace() }
    await gate.waitUntilEntered()
    await model.disconnect()
    await gate.open()
    await refresh.value
    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertTrue(model.projects.isEmpty)
    XCTAssertNil(model.selectedProjectID)
    XCTAssertFalse(model.loadingProjects)
  }

  func testLateConnectResultCannotResurrectAfterDisconnect() async throws {
    let gate = TestGate()
    let service = FakeRemoteService()
    let factory = FakeConnectionFactory(connectServices: [service], connectGate: gate)
    let model = OesapModel(connectionFactory: factory)
    let connecting = Task { await model.connect(.empty) }
    await gate.waitUntilEntered()
    await model.disconnect()
    await gate.open()
    await connecting.value
    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertFalse(model.hasSavedConnection)
    XCTAssertTrue(model.projects.isEmpty)
    let staleServiceClosed = await service.isClosed()
    XCTAssertTrue(staleServiceClosed)
  }

  func testCancelDuringWorkspaceLoadClosesCompletedConnection() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(projectGate: gate, projectGateAtCall: 1)
    let factory = FakeConnectionFactory(connectServices: [service])
    let model = OesapModel(connectionFactory: factory)
    let connecting = Task { await model.connect(.empty) }
    await gate.waitUntilEntered()
    connecting.cancel()
    await gate.open()
    await connecting.value

    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertFalse(model.loadingProjects)
    XCTAssertFalse(model.hasSavedConnection)
    XCTAssertTrue(model.projects.isEmpty)
    let closed = await service.isClosed()
    XCTAssertTrue(closed)
  }

  func testCancelBeforeFactoryCompletesKeepsPriorSavedHost() async throws {
    let gate = TestGate()
    let factory = FakeConnectionFactory(
      connectServices: [FakeRemoteService()], connectGate: gate, initiallySaved: true)
    let model = OesapModel(connectionFactory: factory)
    await model.refreshSavedConnectionState()
    XCTAssertTrue(model.hasSavedConnection)

    let connecting = Task { await model.connect(.empty) }
    await gate.waitUntilEntered()
    connecting.cancel()
    await gate.open()
    await connecting.value

    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertTrue(model.hasSavedConnection)
    XCTAssertFalse(model.loadingProjects)
  }

  func testLateThreadsForOldSelectionCannotOverwriteNewProject() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(threadGateForA: gate)
    let factory = FakeConnectionFactory(connectServices: [service])
    let model = OesapModel(connectionFactory: factory)
    await model.connect(.empty)

    await model.selectProject("B")
    let oldSelection = Task { await model.selectProject("A") }
    await gate.waitUntilEntered()
    await model.selectProject("B")
    await gate.open()
    await oldSelection.value
    XCTAssertEqual(model.selectedProjectID, "B")
    XCTAssertEqual(model.threads.map(\.id), ["thread-B"])
    XCTAssertFalse(model.loadingThreads)
    await model.disconnect()
  }

  func testFailedSendRetainsDraftAndNewDraftSurvivesSuccessfulOldSend() async throws {
    let failing = FakeRemoteService(failsSending: true)
    let factory = FakeConnectionFactory(connectServices: [failing])
    let model = OesapModel(connectionFactory: factory)
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.setDraft("first message", for: "thread-A")
    let failed = await model.send(threadID: "thread-A", text: "first message")
    XCTAssertFalse(failed)
    XCTAssertEqual(model.draft(for: "thread-A"), "first message")
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    await model.disconnect()
    XCTAssertEqual(model.draft(for: "thread-A"), "")

    let gate = TestGate()
    let succeeding = FakeRemoteService(sendGate: gate)
    let nextFactory = FakeConnectionFactory(connectServices: [succeeding])
    let nextModel = OesapModel(connectionFactory: nextFactory)
    await nextModel.connect(.empty)
    nextModel.selectThread("thread-A")
    nextModel.setDraft("original", for: "thread-A")
    let sending = Task { await nextModel.send(threadID: "thread-A", text: "original") }
    await gate.waitUntilEntered()
    nextModel.setDraft("newer draft", for: "thread-A")
    await gate.open()
    let sent = await sending.value
    XCTAssertTrue(sent)
    XCTAssertEqual(nextModel.draft(for: "thread-A"), "newer draft")
    await nextModel.disconnect()
  }

  func testUncertainMessageRetryReplaysImmutableIntentAndPreservesEditedDraft() async throws {
    let service = FakeRemoteService(failSendCalls: [1])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.setDraft("Original text", for: "thread-A")
    let first = await model.send(
      threadID: "thread-A", text: "Original text", behavior: .steer,
      expectedStateRevision: model.threadStateRevision(for: "thread-A"),
      selectedDuringActiveTurn: false)
    XCTAssertFalse(first)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    XCTAssertTrue(model.canRetryAgentMessage(for: "thread-A"))

    model.setDraft("Edited draft", for: "thread-A")
    let retried = await model.retryAgentMessage(threadID: "thread-A")
    XCTAssertTrue(retried)
    XCTAssertEqual(model.draft(for: "thread-A"), "Edited draft")
    let sent = await service.sentMessages()
    XCTAssertEqual(sent.count, 2)
    XCTAssertEqual(sent[0], sent[1])
    XCTAssertEqual(sent[0].behavior, .steer)
    XCTAssertEqual(sent[0].text, "Original text")
    XCTAssertFalse(model.hasUncertainAgentMessage(for: "thread-A"))
    await model.disconnect()
  }

  func testReceiptCapabilityDowngradeDisablesUncertainRetry() async throws {
    let first = FakeRemoteService(receiptSupport: true, failSendCalls: [1])
    let second = FakeRemoteService(receiptSupport: false)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [first], reconnectServices: [second]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.setDraft("Maybe delivered", for: "thread-A")
    let firstAccepted = await model.send(threadID: "thread-A", text: "Maybe delivered")
    XCTAssertFalse(firstAccepted)
    XCTAssertTrue(model.canRetryAgentMessage(for: "thread-A"))

    await model.reconnect()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertFalse(model.canRetryAgentMessage(for: "thread-A"))
    let retried = await model.retryAgentMessage(threadID: "thread-A")
    XCTAssertFalse(retried)
    let secondSends = await second.sentMessages()
    XCTAssertTrue(secondSends.isEmpty)
    XCTAssertEqual(model.draft(for: "thread-A"), "Maybe delivered")
    await model.disconnect()
  }

  func testUncertainMessageIsNotReplayedAgainstDifferentHostWithSameThreadID() async throws {
    let first = FakeRemoteService(failSendCalls: [1], serverIDValue: "host-A")
    let second = FakeRemoteService(serverIDValue: "host-B")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [first], reconnectServices: [second]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let accepted = await model.send(threadID: "thread-A", text: "Host A only")
    XCTAssertFalse(accepted)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    await model.reconnect()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertFalse(model.hasUncertainAgentMessage(for: "thread-A"))
    XCTAssertFalse(model.canRetryAgentMessage(for: "thread-A"))
    let attempted = await model.retryAgentMessage(threadID: "thread-A")
    XCTAssertFalse(attempted)
    let secondSends = await second.sentMessages()
    XCTAssertTrue(secondSends.isEmpty)
    await model.disconnect()
  }

  func testImagesFromPreviousHostAreClearedWhenThreadIDsOverlap() async throws {
    let first = FakeRemoteService(serverIDValue: "host-A")
    let second = FakeRemoteService(serverIDValue: "host-B")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [first], reconnectServices: [second]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    XCTAssertTrue(
      model.addDraftImage(
        RemoteDraftImage(id: "host-A-image", data: Data([1]), mimeType: "image/png"),
        for: "thread-A"))
    await model.reconnect()
    XCTAssertEqual(model.draftImages(for: "thread-A"), [])
    await model.disconnect()
  }

  func testHostImageReadUsesThreadWorkingDirectoryAndRejectsSchemes() async throws {
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      threadCWD: "/fixture/A/worktree")
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let bytes = try await model.loadRemoteImage(
      source: "artifacts/chart.png", threadID: "thread-A")
    XCTAssertEqual(bytes, Data([1, 2, 3]))
    let reads = await service.recordedImageReads()
    XCTAssertEqual(reads.first?.cwd, "/fixture/A/worktree")
    XCTAssertEqual(reads.first?.path, "artifacts/chart.png")
    XCTAssertEqual(reads.first?.maxBytes, RemoteImageLimits.maximumDisplayBytes)
    do {
      _ = try await model.loadRemoteImage(source: "javascript:alert(1)", threadID: "thread-A")
      XCTFail("A URL scheme must not be interpreted as a host file path")
    } catch {}
    let readsAfterRejection = await service.recordedImageReads()
    XCTAssertEqual(readsAfterRejection.count, 1)
    await model.disconnect()
  }

  func testHostImageReadDropsResultAfterThreadSelectionChanges() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      threadCWD: "/fixture/A/worktree", imageReadGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let loading = Task {
      try await model.loadRemoteImage(source: "artifacts/chart.png", threadID: "thread-A")
    }
    await gate.waitUntilEntered()
    model.selectThread("another-thread")
    await gate.open()
    do {
      _ = try await loading.value
      XCTFail("An image from the previous selection must be discarded")
    } catch is CancellationError {}
    await model.disconnect()
  }

  func testUnverifiedHostIdentityDisablesAgentControlWithoutSending() async throws {
    let unverifiedIDs: [String?] = [nil, "unknown", ""]
    for hostID in unverifiedIDs {
      let service = FakeRemoteService(initialThreadState: .running, serverIDValue: hostID)
      let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
      await model.connect(.empty)
      model.selectThread("thread-A")
      XCTAssertFalse(model.agentControlAvailable(for: "thread-A"))

      let sent = await model.send(
        threadID: "thread-A", text: "Do not send", behavior: .steer,
        expectedStateRevision: model.threadStateRevision(for: "thread-A"),
        selectedDuringActiveTurn: true)
      XCTAssertFalse(sent)
      await model.stopAgent(
        threadID: "thread-A", expectedStateRevision: model.threadStateRevision(for: "thread-A"))
      let sends = await service.sentMessages()
      let stops = await service.stopCallCount()
      XCTAssertTrue(sends.isEmpty)
      XCTAssertEqual(stops, 0)
      await model.disconnect()
    }
  }

  func testLateSendFromPriorConnectionCannotClearUncertainIntent() async throws {
    let gate = TestGate()
    let first = FakeRemoteService(sendGate: gate)
    let second = FakeRemoteService()
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [first], reconnectServices: [second]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.setDraft("Original text", for: "thread-A")
    let sending = Task { await model.send(threadID: "thread-A", text: "Original text") }
    await gate.waitUntilEntered()
    await model.reconnect()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    model.setDraft("Edited after reconnect", for: "thread-A")
    await gate.open()
    let oldAccepted = await sending.value
    XCTAssertFalse(oldAccepted)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    XCTAssertEqual(model.draft(for: "thread-A"), "Edited after reconnect")
    let secondSends = await second.sentMessages()
    XCTAssertTrue(secondSends.isEmpty)
    await model.disconnect()
  }

  func testSpontaneousConnectionLossTurnsInFlightSendUncertain() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(sendGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.setDraft("In flight", for: "thread-A")
    let sending = Task { await model.send(threadID: "thread-A", text: "In flight") }
    await gate.waitUntilEntered()
    await service.emitDisconnect("fixture socket loss")
    let disconnected = await eventually { model.connectionState == .disconnected }
    XCTAssertTrue(disconnected)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    XCTAssertFalse(model.isSendingAgentMessage(for: "thread-A"))
    await gate.open()
    let oldAccepted = await sending.value
    XCTAssertFalse(oldAccepted)
    XCTAssertEqual(model.draft(for: "thread-A"), "In flight")
    await model.disconnect()
  }

  func testPendingThreadASendDoesNotBlockOrOverwriteThreadB() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(
      sendGate: gate, sendGateAgentID: "thread-A", failSendCalls: [1])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.setDraft("A may be delivered", for: "thread-A")
    let sendingA = Task { await model.send(threadID: "thread-A", text: "A may be delivered") }
    await gate.waitUntilEntered()

    await model.selectProject("B")
    model.selectThread("thread-B")
    model.setDraft("B sends now", for: "thread-B")
    let sentB = await model.send(threadID: "thread-B", text: "B sends now")
    XCTAssertTrue(sentB)
    XCTAssertEqual(model.draft(for: "thread-B"), "")
    XCTAssertEqual(model.agentSendFeedback(for: "thread-B")?.phase, .accepted)

    await gate.open()
    let sentA = await sendingA.value
    XCTAssertFalse(sentA)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    XCTAssertEqual(model.draft(for: "thread-A"), "A may be delivered")
    XCTAssertEqual(model.agentSendFeedback(for: "thread-B")?.phase, .accepted)
    let calls = await service.sentMessages()
    XCTAssertEqual(calls.map(\.agentID), ["thread-A", "thread-B"])
    await model.disconnect()
  }

  func testUncertainSendCanStillBeReviewedAndDiscardedAfterStop() async throws {
    let snapshot = RemoteAgentControlSnapshot(
      id: "thread-A", state: .idle, requiresAttention: false, attentionReason: nil)
    let service = FakeRemoteService(
      failSendCalls: [1], stopSnapshot: snapshot, initialThreadState: .running)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.setDraft("Might have arrived", for: "thread-A")
    let sent = await model.send(
      threadID: "thread-A", text: "Might have arrived", behavior: .steer,
      expectedStateRevision: model.threadStateRevision(for: "thread-A"),
      selectedDuringActiveTurn: true)
    XCTAssertFalse(sent)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))

    await model.stopAgent(
      threadID: "thread-A", expectedStateRevision: model.threadStateRevision(for: "thread-A"))
    XCTAssertEqual(model.threads.first?.state, .idle)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    XCTAssertTrue(model.requiresAgentMessageReview(for: "thread-A"))
    model.discardUncertainAgentMessage(threadID: "thread-A")
    XCTAssertFalse(model.hasUncertainAgentMessage(for: "thread-A"))
    XCTAssertEqual(model.draft(for: "thread-A"), "Might have arrived")
    let later = await model.send(threadID: "thread-A", text: "Fresh intent")
    XCTAssertTrue(later)
    let calls = await service.sentMessages()
    XCTAssertEqual(calls.count, 2)
    XCTAssertNotEqual(calls[0].messageID, calls[1].messageID)
    await model.disconnect()
  }

  func testStopNullResponseWaitsForAuthoritativeStateAndPreventsDuplicateRequest() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(stopGate: gate, initialThreadState: .running)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let revision = model.threadStateRevision(for: "thread-A")
    let stopping = Task {
      await model.stopAgent(threadID: "thread-A", expectedStateRevision: revision)
    }
    await gate.waitUntilEntered()
    await model.stopAgent(threadID: "thread-A", expectedStateRevision: revision)
    let stopCount = await service.stopCallCount()
    XCTAssertEqual(stopCount, 1)
    await gate.open()
    await stopping.value
    XCTAssertEqual(model.agentActionFeedback(for: "thread-A")?.phase, .stopWaiting)
    XCTAssertEqual(model.threads.first?.state, .running)
    await model.disconnect()
  }

  func testStopRefusalAndStaleSnapshotDoNotClaimStopped() async throws {
    let refusedService = FakeRemoteService(
      stopError: RemoteServiceError.unavailable("refused"), initialThreadState: .running)
    let refusedModel = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [refusedService]))
    await refusedModel.connect(.empty)
    refusedModel.selectThread("thread-A")
    await refusedModel.stopAgent(
      threadID: "thread-A",
      expectedStateRevision: refusedModel.threadStateRevision(for: "thread-A"))
    XCTAssertEqual(refusedModel.agentActionFeedback(for: "thread-A")?.phase, .failed)
    XCTAssertEqual(refusedModel.threads.first?.state, .running)
    await refusedModel.disconnect()

    let gate = TestGate()
    let snapshot = RemoteAgentControlSnapshot(
      id: "thread-A", state: .idle, requiresAttention: false, attentionReason: nil)
    let service = FakeRemoteService(
      stopGate: gate, stopSnapshot: snapshot, initialThreadState: .running)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let watching = Task { await model.watchTimeline(threadID: "thread-A") }
    let subscribed = await eventually { await service.subscriptionCount() > 0 }
    XCTAssertTrue(subscribed)
    let revision = model.threadStateRevision(for: "thread-A")
    let stopping = Task {
      await model.stopAgent(threadID: "thread-A", expectedStateRevision: revision)
    }
    await gate.waitUntilEntered()
    await service.emit(.threadState(.running, requiresAttention: false, reason: nil))
    let liveEventApplied = await eventually {
      model.threadStateRevision(for: "thread-A") > revision
    }
    XCTAssertTrue(liveEventApplied)
    await gate.open()
    await stopping.value
    XCTAssertEqual(model.agentActionFeedback(for: "thread-A")?.phase, .stopWaiting)
    XCTAssertEqual(model.threads.first?.state, .running)
    watching.cancel()
    await model.disconnect()
    await watching.value
  }

  func testStopUsesMatchingTerminalSnapshot() async throws {
    let snapshot = RemoteAgentControlSnapshot(
      id: "thread-A", state: .idle, requiresAttention: true, attentionReason: "Review")
    let service = FakeRemoteService(
      stopSnapshot: snapshot, initialThreadState: .running)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    await model.stopAgent(
      threadID: "thread-A", expectedStateRevision: model.threadStateRevision(for: "thread-A"))
    XCTAssertEqual(model.threads.first?.state, .idle)
    XCTAssertTrue(model.threads.first?.requiresAttention == true)
    XCTAssertEqual(model.threads.first?.attentionReason, "Review")
    XCTAssertEqual(model.agentActionFeedback(for: "thread-A")?.phase, .stopped)
    await model.disconnect()
  }

  func testFirstMessageCreatesOnlyOnSendAndUsesConfiguredProjectAgent() async throws {
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")])
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]),
      agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    let draftKey = model.newThreadDraftKey(for: "A")
    model.setDraft("Build it", for: draftKey)
    let beforeCount = await service.creationCount()
    XCTAssertEqual(beforeCount, 0)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: "model-B"), for: "A"))

    let threadID = await model.sendFirstMessage(projectID: "A", text: "Build it")
    XCTAssertEqual(threadID, "new-thread")
    XCTAssertEqual(model.selectedThreadID, "new-thread")
    XCTAssertEqual(model.threads.first?.id, "new-thread")
    XCTAssertEqual(model.draft(for: draftKey), "")
    let intents = await service.creationIntents()
    let intent = try XCTUnwrap(intents.first)
    XCTAssertEqual(intent.projectID, "A")
    XCTAssertEqual(intent.provider, "codex")
    XCTAssertEqual(intent.model, "model-B")
    XCTAssertEqual(intent.cwd, "/fixture/A")
    XCTAssertEqual(intent.prompt, "Build it")
    await model.disconnect()
  }

  func testImageOnlyFirstMessageCreatesThreadAndTransfersNewerDraftImages() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      creationGate: gate)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]),
      agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: nil), for: "A"))
    let draftKey = model.newThreadDraftKey(for: "A")
    let first = RemoteDraftImage(id: "first", data: Data([1]), mimeType: "image/png")
    let second = RemoteDraftImage(id: "second", data: Data([2]), mimeType: "image/png")
    XCTAssertTrue(model.addDraftImage(first, for: draftKey))
    let creating = Task { await model.sendFirstMessage(projectID: "A", text: "") }
    await gate.waitUntilEntered()
    XCTAssertTrue(model.addDraftImage(second, for: draftKey))
    await gate.open()
    let threadID = await creating.value
    XCTAssertEqual(threadID, "new-thread")
    let intents = await service.creationIntents()
    XCTAssertEqual(intents.first?.prompt, "")
    XCTAssertEqual(intents.first?.images, [first])
    XCTAssertEqual(model.draftImages(for: draftKey), [])
    XCTAssertEqual(model.draftImages(for: "new-thread"), [second])
    await model.disconnect()
  }

  func testImageOnlyCreationRetryKeepsOriginalImageAfterDraftRemoval() async throws {
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      failFirstCreation: true)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]),
      agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: nil), for: "A"))
    let draftKey = model.newThreadDraftKey(for: "A")
    let image = RemoteDraftImage(id: "image", data: Data([1]), mimeType: "image/png")
    XCTAssertTrue(model.addDraftImage(image, for: draftKey))
    let firstResult = await model.sendFirstMessage(projectID: "A", text: "")
    XCTAssertNil(firstResult)
    model.removeDraftImage(id: image.id, for: draftKey)
    let result = await model.sendFirstMessage(projectID: "A", text: "")
    XCTAssertEqual(result, "new-thread")
    let intents = await service.creationIntents()
    XCTAssertEqual(intents.count, 2)
    XCTAssertEqual(intents[0], intents[1])
    XCTAssertEqual(intents[0].images, [image])
    await model.disconnect()
  }

  func testAmbiguousCreateReplaysOriginalIntentAndKeepsEditedDraft() async throws {
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      failFirstCreation: true)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]),
      agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: nil), for: "A"))
    let draftKey = model.newThreadDraftKey(for: "A")
    model.setDraft("original", for: draftKey)
    let firstResult = await model.sendFirstMessage(projectID: "A", text: "original")
    XCTAssertNil(firstResult)
    model.setDraft("edited while uncertain", for: draftKey)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "other", model: "new-model"), for: "A"))

    let threadID = await model.sendFirstMessage(projectID: "A", text: "edited while uncertain")
    XCTAssertEqual(threadID, "new-thread")
    let intents = await service.creationIntents()
    XCTAssertEqual(intents.count, 2)
    XCTAssertEqual(intents[0], intents[1])
    XCTAssertEqual(model.draft(for: "new-thread"), "edited while uncertain")
    await model.disconnect()
  }

  func testAmbiguousCreateReusesIntentAcrossReconnect() async throws {
    let fixtureProject = RemoteProject(
      id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")
    let first = FakeRemoteService(projects: [fixtureProject], failFirstCreation: true)
    let second = FakeRemoteService(projects: [fixtureProject])
    let factory = FakeConnectionFactory(
      connectServices: [first], reconnectServices: [second])
    let model = OesapModel(
      connectionFactory: factory, agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: nil), for: "A"))
    let draftKey = model.newThreadDraftKey(for: "A")
    model.setDraft("original", for: draftKey)
    let firstResult = await model.sendFirstMessage(projectID: "A", text: "original")
    XCTAssertNil(firstResult)

    await model.reconnect()
    let secondResult = await model.sendFirstMessage(projectID: "A", text: "original")
    XCTAssertEqual(secondResult, "new-thread")
    let firstIntents = await first.creationIntents()
    let secondIntents = await second.creationIntents()
    XCTAssertEqual(firstIntents.first, secondIntents.first)
    await model.disconnect()
  }

  func testDefinitivePreAgentFailureAllowsCorrectedSettingAndNewIntent() async throws {
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      failFirstCreationDefinitively: true)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]),
      agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "bad-provider", model: nil), for: "A"))
    let draftKey = model.newThreadDraftKey(for: "A")
    model.setDraft("start", for: draftKey)
    let firstResult = await model.sendFirstMessage(projectID: "A", text: "start")
    XCTAssertNil(firstResult)
    XCTAssertEqual(model.draft(for: draftKey), "start")
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: nil), for: "A"))
    let secondResult = await model.sendFirstMessage(projectID: "A", text: "start")
    XCTAssertEqual(secondResult, "new-thread")
    let intents = await service.creationIntents()
    XCTAssertEqual(intents.count, 2)
    XCTAssertNotEqual(intents[0].idempotencyKey, intents[1].idempotencyKey)
    XCTAssertEqual(intents[1].provider, "codex")
    await model.disconnect()
  }

  func testKnownCreatedAgentWithFailedPromptMigratesDraftWithoutDuplicate() async throws {
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      promptAccepted: false)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]),
      agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: nil), for: "A"))
    let draftKey = model.newThreadDraftKey(for: "A")
    model.setDraft("first prompt", for: draftKey)
    let threadID = await model.sendFirstMessage(projectID: "A", text: "first prompt")
    XCTAssertEqual(threadID, "new-thread")
    XCTAssertEqual(model.draft(for: "new-thread"), "first prompt")
    XCTAssertNotNil(model.messageError)
    let creationCount = await service.creationCount()
    XCTAssertEqual(creationCount, 1)
    await model.disconnect()
  }

  func testLateCreateCannotReplaceSelectedExistingThread() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      creationGate: gate)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]),
      agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: nil), for: "A"))
    let draftKey = model.newThreadDraftKey(for: "A")
    model.setDraft("start", for: draftKey)
    let creating = Task { await model.sendFirstMessage(projectID: "A", text: "start") }
    await gate.waitUntilEntered()
    model.selectThread("thread-A")
    await gate.open()
    let result = await creating.value
    XCTAssertNil(result)
    XCTAssertEqual(model.selectedThreadID, "thread-A")
    XCTAssertEqual(model.draft(for: draftKey), "start")
    await model.disconnect()
  }

  func testClearedDraftDoesNotResurrectAcceptedFirstPrompt() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(
      projects: [.init(id: "A", name: "Project A", subtitle: nil, rootPath: "/fixture/A")],
      creationGate: gate)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]),
      agentConfigurationStore: isolatedAgentStore())
    await model.connect(.empty)
    XCTAssertTrue(
      model.saveAgentConfiguration(
        RemoteAgentConfiguration(provider: "codex", model: nil), for: "A"))
    let draftKey = model.newThreadDraftKey(for: "A")
    model.setDraft("original", for: draftKey)
    let creating = Task { await model.sendFirstMessage(projectID: "A", text: "original") }
    await gate.waitUntilEntered()
    model.setDraft("", for: draftKey)
    await gate.open()
    let threadID = await creating.value
    XCTAssertEqual(threadID, "new-thread")
    XCTAssertEqual(model.draft(for: "new-thread"), "")
    await model.disconnect()
  }

  func testCrossServerProjectsLoadIndependentlyAndOpenCollidingProjectIDs() async {
    let gate = TestGate()
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(
      projectGate: gate, projectGateAtCall: 1, initialThreadState: .waiting,
      serverIDValue: "server-b")
    let model = multiServerModel(first: first, second: second)
    await model.start()
    model.selectThread("thread-A")
    model.setDraft("Work draft", for: "thread-A")
    let refresh = Task { await model.beginProjectCatalog() }
    await gate.waitUntilEntered()
    let firstLoaded = await eventually {
      model.allHostProjectCatalogs.first(where: { $0.id == "one" })?.projects.count == 2
    }
    XCTAssertTrue(firstLoaded)
    XCTAssertEqual(model.activeInstanceID, "one")
    XCTAssertEqual(model.draft(for: "thread-A"), "Work draft")
    await gate.open()
    await refresh.value
    XCTAssertEqual(model.projectCatalogHosts.map(\.instance.name), ["Home server", "Work server"])
    let unnecessaryThreads = await second.threadBCallCount()
    XCTAssertEqual(unnecessaryThreads, 0, "Project catalogs must not fetch agent threads")

    let opened = await model.openServerProject(instanceID: "two", projectID: "A")
    XCTAssertTrue(opened)
    XCTAssertEqual(model.activeInstanceID, "two")
    XCTAssertEqual(model.selectedProjectID, "A")
    XCTAssertEqual(model.threads.first?.state, .waiting)
    XCTAssertEqual(model.draft(for: "thread-A"), "")
    let returned = await model.openServerProject(instanceID: "one", projectID: "A")
    XCTAssertTrue(returned)
    XCTAssertEqual(model.draft(for: "thread-A"), "Work draft")
    model.endProjectCatalog()
    await model.disconnect()
  }

  func testCrossServerProjectsRetainFailedCatalogAndShareVisibleOverviewConnections() async {
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(projectErrorCalls: [2], serverIDValue: "server-b")
    let model = multiServerModel(first: first, second: second)
    await model.start()
    await model.beginProjectCatalog()
    let previous = model.allHostProjectCatalogs.first(where: { $0.id == "two" })
    await model.refreshAllHostProjects()
    let failed = model.allHostProjectCatalogs.first(where: { $0.id == "two" })
    XCTAssertEqual(failed?.projects, previous?.projects)
    XCTAssertEqual(failed?.updatedAt, previous?.updatedAt)
    XCTAssertEqual(failed?.isStale, true)
    XCTAssertEqual(failed?.isLoading, false)
    XCTAssertEqual(failed?.isConnectionUnavailable, false)
    XCTAssertNotNil(failed?.error)
    await model.beginAgentOverview()
    model.endAgentOverview()
    let remainsConnected = await second.isClosed()
    XCTAssertFalse(remainsConnected, "Projects is still using this server's connection")
    await model.refreshAllHostProjects()
    XCTAssertEqual(model.allHostProjectCatalogs.first(where: { $0.id == "two" })?.isStale, false)
    model.endProjectCatalog()
    let closed = await eventually { await second.isClosed() }
    XCTAssertTrue(closed)
    let activeClosed = await first.isClosed()
    XCTAssertFalse(activeClosed)
    await model.disconnect()
  }

  func testFailedServerHidesItsLoadingStateWithoutMarkingHealthyServerDisconnected() async {
    let first = FakeRemoteService(serverIDValue: "server-a")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "one", name: "Work server", subtitle: ""),
          .init(id: "unreachable", name: "Offline server", subtitle: ""),
        ], activeInstanceID: "one", instanceServices: ["one": first]))
    await model.start()
    await model.beginProjectCatalog()
    let healthy = model.allHostProjectCatalogs.first(where: { $0.id == "one" })
    let unreachable = model.allHostProjectCatalogs.first(where: { $0.id == "unreachable" })
    XCTAssertEqual(healthy?.isLoading, false)
    XCTAssertEqual(healthy?.isConnectionUnavailable, false)
    XCTAssertNil(healthy?.error)
    XCTAssertEqual(unreachable?.isLoading, false)
    XCTAssertEqual(unreachable?.isConnectionUnavailable, true)
    XCTAssertNotNil(unreachable?.error)
    model.endProjectCatalog()
    await model.disconnect()
  }

  func testOverlappingProjectCatalogRefreshesShareOneBatch() async {
    let gate = TestGate()
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(
      projectGate: gate, projectGateAtCall: 1, serverIDValue: "server-b")
    let model = multiServerModel(first: first, second: second)
    await model.start()
    let initial = Task { await model.beginProjectCatalog() }
    await gate.waitUntilEntered()
    var joined = false
    let pullRefresh = Task {
      joined = true
      await model.refreshAllHostProjects()
    }
    let didJoin = await eventually { joined }
    XCTAssertTrue(didJoin)
    await gate.open()
    await initial.value
    await pullRefresh.value
    let firstCalls = await first.projectCallCount()
    let secondCalls = await second.projectCallCount()
    XCTAssertEqual(firstCalls, 2, "One startup request and one shared catalog request")
    XCTAssertEqual(secondCalls, 1, "Overlapping refreshes must not start another batch")
    XCTAssertFalse(model.loadingAllHostProjects)
    model.endProjectCatalog()
    await model.disconnect()
  }

  func testFailedProjectCatalogRetryKeepsErrorWithoutLoadingIndicator() async {
    let gate = TestGate()
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(
      projectErrorCalls: [1], projectGate: gate, projectGateAtCall: 2,
      serverIDValue: "server-b")
    let model = multiServerModel(first: first, second: second)
    await model.start()
    await model.beginProjectCatalog()
    let previousError = model.allHostProjectCatalogs.first(where: { $0.id == "two" })?.error
    XCTAssertNotNil(previousError)
    let retry = Task { await model.refreshAllHostProjects() }
    await gate.waitUntilEntered()
    let retrying = model.allHostProjectCatalogs.first(where: { $0.id == "two" })
    XCTAssertEqual(retrying?.error, previousError)
    XCTAssertEqual(retrying?.isLoading, false)
    await gate.open()
    await retry.value
    let recovered = model.allHostProjectCatalogs.first(where: { $0.id == "two" })
    XCTAssertNil(recovered?.error)
    XCTAssertEqual(recovered?.projects.count, 2)
    XCTAssertEqual(recovered?.isStale, false)
    model.endProjectCatalog()
    await model.disconnect()
  }

  func testProjectCatalogRefreshRecoversLostSelectedServerAndKeepsOtherServerUsable() async {
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(serverIDValue: "server-b")
    let model = multiServerModel(first: first, second: second)
    await model.start()
    await model.beginProjectCatalog()
    await first.setProjectsError(RemoteServiceError.connectionLost("Connection closed"))
    await model.refreshAllHostProjects()
    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertEqual(
      model.projectCatalogHosts.first(where: { $0.id == "one" })?.isConnectionUnavailable, true)
    XCTAssertNil(model.projectCatalogHosts.first(where: { $0.id == "two" })?.error)
    await first.setProjectsError(nil)
    await model.refreshAllHostProjects()
    let recovered = model.projectCatalogHosts.first(where: { $0.id == "one" })
    XCTAssertNil(recovered?.error)
    XCTAssertEqual(recovered?.isConnectionUnavailable, false)
    XCTAssertEqual(recovered?.isLoading, false)
    let opened = await model.openServerProject(instanceID: "one", projectID: "A")
    XCTAssertTrue(opened, "The recovered connection must be promoted when its project opens")
    model.endProjectCatalog()
    await model.disconnect()
  }

  func testRemovingServerDuringProjectCatalogRejectsLateCatalog() async {
    let gate = TestGate()
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(
      projectGate: gate, projectGateAtCall: 1, serverIDValue: "server-b")
    let model = multiServerModel(first: first, second: second)
    await model.start()
    let refresh = Task { await model.beginProjectCatalog() }
    await gate.waitUntilEntered()
    await model.removeSavedInstance("two")
    await gate.open()
    await refresh.value
    await model.refreshAllHostProjects()
    XCTAssertEqual(model.allHostProjectCatalogs.map(\.id), ["one"])
    let removedClosed = await second.isClosed()
    XCTAssertTrue(removedClosed)
    model.endProjectCatalog()
    await model.disconnect()
  }

  func testSwitchingServersPreservesUncertainSendWithoutResendingToAnotherHost() async {
    let gate = TestGate()
    let first = FakeRemoteService(sendGate: gate, serverIDValue: "server-a")
    let second = FakeRemoteService(serverIDValue: "server-b")
    let model = multiServerModel(first: first, second: second)
    await model.start()
    await model.beginProjectCatalog()
    model.selectThread("thread-A")
    model.setDraft("May have been delivered", for: "thread-A")
    let sending = Task { await model.send(threadID: "thread-A", text: "May have been delivered") }
    await gate.waitUntilEntered()
    let opened = await model.openServerProject(instanceID: "two", projectID: "A")
    XCTAssertTrue(opened)
    XCTAssertFalse(model.hasUncertainAgentMessage(for: "thread-A"))
    let returned = await model.openServerProject(instanceID: "one", projectID: "A")
    XCTAssertTrue(returned)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    await gate.open()
    let accepted = await sending.value
    XCTAssertFalse(accepted)
    XCTAssertTrue(model.hasUncertainAgentMessage(for: "thread-A"))
    let wrongHostSends = await second.sentMessages()
    XCTAssertTrue(wrongHostSends.isEmpty)
    let originalSends = await first.sentMessages()
    XCTAssertEqual(originalSends.count, 1)
    model.endProjectCatalog()
    await model.disconnect()
  }

  private func multiServerModel(first: FakeRemoteService, second: FakeRemoteService) -> OesapModel {
    OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "one", name: "Work server", subtitle: ""),
          .init(id: "two", name: "Home server", subtitle: ""),
        ], activeInstanceID: "one", instanceServices: ["one": first, "two": second]))
  }

  func testAllHostOverviewPublishesHealthyHostBeforeSlowHostAndRoutesCollidingIDs() async {
    let gate = TestGate()
    let first = FakeRemoteService(initialThreadState: .running, serverIDValue: "server-a")
    let second = FakeRemoteService(
      projectGate: gate, projectGateAtCall: 1,
      initialThreadState: .waiting, serverIDValue: "server-b")
    let factory = FakeConnectionFactory(
      connectServices: [],
      initiallySavedInstances: [
        .init(id: "one", name: "Work server", subtitle: ""),
        .init(id: "two", name: "Home server", subtitle: ""),
      ], activeInstanceID: "one", instanceServices: ["one": first, "two": second])
    let model = OesapModel(connectionFactory: factory)
    await model.start()
    model.selectThread("thread-A")
    model.setDraft("Work draft", for: "thread-A")
    let refresh = Task { await model.beginAgentOverview() }
    await gate.waitUntilEntered()
    let firstLoaded = await eventually {
      model.allHostAgentOverviewSnapshots.first(where: { $0.id == "one" })?.groups.count == 2
    }
    XCTAssertTrue(firstLoaded)
    XCTAssertEqual(model.activeInstanceID, "one")
    XCTAssertEqual(model.selectedThreadID, "thread-A")
    XCTAssertEqual(model.draft(for: "thread-A"), "Work draft")
    let activeClosed = await first.isClosed()
    XCTAssertFalse(activeClosed)
    await gate.open()
    await refresh.value
    XCTAssertEqual(model.agentOverviewHosts.map(\.id), ["two", "one"])
    XCTAssertEqual(model.agentOverviewHosts.map(\.instance.name), ["Home server", "Work server"])
    XCTAssertEqual(model.agentOverviewHosts.flatMap(\.entries).count, 4)
    let calls = await factory.overviewCalls()
    XCTAssertEqual(calls, ["two"])

    let opened = await model.openOverviewAgent(
      instanceID: "two", projectID: "A", threadID: "thread-A")
    XCTAssertTrue(opened)
    XCTAssertEqual(model.activeInstanceID, "two")
    XCTAssertEqual(model.selectedThreadID, "thread-A")
    XCTAssertEqual(model.draft(for: "thread-A"), "")
    model.setDraft("Home draft", for: "thread-A")
    let sent = await model.send(threadID: "thread-A", text: "Home message")
    XCTAssertTrue(sent)
    let firstSends = await first.sentMessages()
    let secondSends = await second.sentMessages()
    XCTAssertTrue(firstSends.isEmpty)
    XCTAssertEqual(secondSends.map(\.text), ["Home message"])

    let returned = await model.openOverviewAgent(
      instanceID: "one", projectID: "A", threadID: "thread-A")
    XCTAssertTrue(returned)
    XCTAssertEqual(model.draft(for: "thread-A"), "Work draft")
    model.endAgentOverview()
    await model.disconnect()
  }

  func testAllHostOverviewDeduplicatesAuthenticatedServersButNotMatchingNames() async {
    let first = FakeRemoteService(serverIDValue: "same-server")
    let second = FakeRemoteService(serverIDValue: "same-server")
    let third = FakeRemoteService(serverIDValue: "other-server")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "one", name: "Server", subtitle: ""),
          .init(id: "two", name: "Server", subtitle: ""),
          .init(id: "three", name: "Server", subtitle: ""),
        ], activeInstanceID: "one", instanceServices: ["one": first, "two": second, "three": third])
    )
    await model.start()
    await model.beginAgentOverview()
    XCTAssertEqual(model.allHostAgentOverviewSnapshots.count, 3)
    XCTAssertEqual(Set(model.agentOverviewHosts.map(\.id)), ["one", "three"])
    XCTAssertEqual(model.agentOverviewHosts.flatMap(\.entries).count, 4)
    model.endAgentOverview()
    await model.disconnect()
  }

  func testAllHostOverviewFailureRetainsHostSnapshotAndSelectedChat() async {
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(projectErrorCalls: [2], serverIDValue: "server-b")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "one", name: "Work", subtitle: ""),
          .init(id: "two", name: "Home", subtitle: ""),
        ], activeInstanceID: "one", instanceServices: ["one": first, "two": second]))
    await model.start()
    model.selectThread("thread-A")
    await model.beginAgentOverview()
    let previous = model.allHostAgentOverviewSnapshots.first(where: { $0.id == "two" })
    await model.refreshAllHostAgentOverview()
    let failed = model.allHostAgentOverviewSnapshots.first(where: { $0.id == "two" })
    XCTAssertEqual(failed?.groups, previous?.groups)
    XCTAssertEqual(failed?.updatedAt, previous?.updatedAt)
    XCTAssertEqual(failed?.isStale, true)
    XCTAssertNotNil(failed?.error)
    XCTAssertEqual(model.activeInstanceID, "one")
    XCTAssertEqual(model.selectedThreadID, "thread-A")
    let closed = await first.isClosed()
    XCTAssertFalse(closed)
    await model.refreshAllHostAgentOverview()
    XCTAssertEqual(
      model.allHostAgentOverviewSnapshots.first(where: { $0.id == "two" })?.isStale, false)
    model.endAgentOverview()
    let overviewClosed = await eventually { await second.isClosed() }
    XCTAssertTrue(overviewClosed)
    let selectedClosed = await first.isClosed()
    XCTAssertFalse(selectedClosed)
    await model.disconnect()
  }

  func testRemovingHostDuringOverviewRefreshRejectsLateRows() async {
    let gate = TestGate()
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(
      projectGate: gate, projectGateAtCall: 1, serverIDValue: "server-b")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "one", name: "Work", subtitle: ""),
          .init(id: "two", name: "Home", subtitle: ""),
        ], activeInstanceID: "one", instanceServices: ["one": first, "two": second]))
    await model.start()
    let refresh = Task { await model.beginAgentOverview() }
    await gate.waitUntilEntered()
    await model.removeSavedInstance("two")
    await gate.open()
    await refresh.value
    await model.refreshAllHostAgentOverview()
    XCTAssertEqual(model.allHostAgentOverviewSnapshots.map(\.id), ["one"])
    let removedClosed = await second.isClosed()
    XCTAssertTrue(removedClosed)
    XCTAssertEqual(model.activeInstanceID, "one")
    model.endAgentOverview()
    await model.disconnect()
  }

  func testBackgroundCancelsOverviewAndForegroundReloadsWithoutClosingSelectedChat() async {
    let first = FakeRemoteService(serverIDValue: "server-a")
    let second = FakeRemoteService(serverIDValue: "server-b")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [],
        initiallySavedInstances: [
          .init(id: "one", name: "Work", subtitle: ""),
          .init(id: "two", name: "Home", subtitle: ""),
        ], activeInstanceID: "one", instanceServices: ["one": first, "two": second]))
    await model.start()
    await model.beginAgentOverview()
    model.appDidEnterBackground()
    let overviewClosed = await eventually { await second.isClosed() }
    XCTAssertTrue(overviewClosed)
    XCTAssertTrue(model.allHostAgentOverviewSnapshots.allSatisfy(\.isStale))
    let selectedClosed = await first.isClosed()
    XCTAssertFalse(selectedClosed)
    await model.appDidBecomeActive()
    await model.refreshAllHostAgentOverview()
    XCTAssertTrue(model.allHostAgentOverviewSnapshots.allSatisfy { !$0.isStale })
    XCTAssertEqual(model.activeInstanceID, "one")
    model.endAgentOverview()
    await model.disconnect()
  }

  func testOverviewOrdersAttentionBeforeRecencyAcrossProjects() {
    func thread(_ id: String, state: RemoteThread.State, attention: Bool, activity: Double?)
      -> RemoteThread
    {
      RemoteThread(
        id: id, title: id, provider: nil, model: nil, state: state,
        requiresAttention: attention, attentionReason: nil,
        lastActivityAt: activity.map { Date(timeIntervalSince1970: $0) })
    }
    let groups = [
      RemoteAgentOverviewGroup(
        project: RemoteProject(id: "A", name: "First project", subtitle: nil),
        threads: [
          thread("newest", state: .running, attention: false, activity: 500),
          thread("waiting", state: .waiting, attention: false, activity: 200),
          thread("unknown-date", state: .running, attention: false, activity: nil),
        ], error: nil),
      RemoteAgentOverviewGroup(
        project: RemoteProject(id: "B", name: "Second project", subtitle: nil),
        threads: [
          thread("failed", state: .failed, attention: true, activity: 100),
          thread("flagged", state: .running, attention: true, activity: 300),
          thread("older", state: .idle, attention: false, activity: 400),
          thread("attention-unknown-date", state: .idle, attention: true, activity: nil),
        ], error: "Last-known rows"),
    ]

    let entries = RemoteAgentOverviewEntry.sortedEntries(in: groups)
    XCTAssertEqual(
      entries.map(\.thread.id),
      ["flagged", "waiting", "failed", "attention-unknown-date", "newest", "older", "unknown-date"])
    XCTAssertEqual(entries.first?.project.id, "B")
    XCTAssertEqual(entries[1].project.id, "A")
  }

  func testOverviewRecencyTiesAreStableAndRowIdentityIncludesProject() {
    let first = RemoteThread(
      id: "same", title: "Thread", provider: nil, model: nil, state: .running,
      requiresAttention: false, attentionReason: nil,
      lastActivityAt: Date(timeIntervalSince1970: 100))
    var second = first
    second.id = "second"
    let groups = [
      RemoteAgentOverviewGroup(
        project: RemoteProject(id: "B", name: "Project B", subtitle: nil),
        threads: [first], error: nil),
      RemoteAgentOverviewGroup(
        project: RemoteProject(id: "A", name: "Project A", subtitle: nil),
        threads: [second, first], error: nil),
    ]
    let entries = RemoteAgentOverviewEntry.sortedEntries(in: groups)
    XCTAssertEqual(entries.map(\.project.id), ["A", "A", "B"])
    XCTAssertEqual(entries.map(\.thread.id), ["same", "second", "same"])
    XCTAssertEqual(Set(entries.map(\.id)).count, 3)
    XCTAssertEqual(RemoteAgentOverviewEntry.sortedEntries(in: groups.reversed()), entries)
  }

  func testAgentOverviewKeepsSelectedChatAndShowsPartialProjectError() async throws {
    let service = FakeRemoteService(threadErrorForB: true)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")

    await model.refreshAgentOverview()
    XCTAssertEqual(model.agentOverviewGroups.map(\.id), ["A", "B"])
    XCTAssertEqual(model.agentOverviewGroups[0].threads.map(\.id), ["thread-A"])
    XCTAssertNil(model.agentOverviewGroups[0].error)
    XCTAssertNotNil(model.agentOverviewGroups[1].error)
    XCTAssertNotNil(model.agentOverviewError)
    XCTAssertTrue(model.agentOverviewIsStale)
    XCTAssertEqual(model.selectedProjectID, "A")
    XCTAssertEqual(model.selectedThreadID, "thread-A")
    XCTAssertEqual(model.threads.map(\.id), ["thread-A"])
    XCTAssertFalse(model.openAgent(projectID: "B", threadID: "thread-B"))
    await model.disconnect()
  }

  func testOverviewRowOpensAgentWithoutReloadingProjectThreads() async throws {
    let service = FakeRemoteService()
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    await model.refreshAgentOverview()
    let before = await service.threadBCallCount()

    XCTAssertTrue(model.openAgent(projectID: "B", threadID: "thread-B"))
    XCTAssertEqual(model.selectedProjectID, "B")
    XCTAssertEqual(model.selectedThreadID, "thread-B")
    XCTAssertEqual(model.threads.map(\.id), ["thread-B"])
    let after = await service.threadBCallCount()
    XCTAssertEqual(after, before)
    await model.disconnect()
  }

  func testOverviewStaysMarkedStaleOnLossAndClearsOnExplicitDisconnect() async throws {
    let service = FakeRemoteService()
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    await model.refreshAgentOverview()
    XCTAssertEqual(model.agentOverviewGroups.count, 2)
    XCTAssertFalse(model.agentOverviewIsStale)
    XCTAssertNotNil(model.agentOverviewUpdatedAt)

    await service.emitDisconnect("fixture loss")
    let disconnected = await eventually { model.connectionState == .disconnected }
    XCTAssertTrue(disconnected)
    XCTAssertEqual(model.agentOverviewGroups.count, 2)
    XCTAssertTrue(model.agentOverviewIsStale)
    XCTAssertFalse(model.openAgent(projectID: "A", threadID: "thread-A"))

    await model.disconnect()
    XCTAssertTrue(model.agentOverviewGroups.isEmpty)
    XCTAssertFalse(model.agentOverviewIsStale)
    XCTAssertNil(model.agentOverviewUpdatedAt)
  }

  func testLateOverviewRefreshCannotResurrectAfterDisconnect() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(threadGateForA: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    let refreshing = Task { await model.refreshAgentOverview() }
    await gate.waitUntilEntered()
    await model.disconnect()
    await gate.open()
    await refreshing.value
    XCTAssertTrue(model.agentOverviewGroups.isEmpty)
    XCTAssertFalse(model.loadingAgentOverview)
  }

  func testOverviewDiscoversNewProjectWithoutChangingSelectedChat() async throws {
    let projectC = RemoteProject(id: "C", name: "Project C", subtitle: nil)
    let service = FakeRemoteService(
      projectsAfterFirstCall: [
        .init(id: "A", name: "Project A", subtitle: nil),
        .init(id: "B", name: "Project B", subtitle: nil),
        projectC,
      ])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    XCTAssertEqual(model.projects.map(\.id), ["A", "B"])

    await model.refreshAgentOverview()
    XCTAssertEqual(model.agentOverviewGroups.map(\.id), ["A", "B", "C"])
    XCTAssertEqual(model.selectedProjectID, "A")
    XCTAssertEqual(model.selectedThreadID, "thread-A")
    XCTAssertEqual(model.projects.map(\.id), ["A", "B"])
    XCTAssertTrue(model.openAgent(projectID: "C", threadID: "thread-C"))
    XCTAssertEqual(model.selectedProjectID, "C")
    XCTAssertEqual(model.selectedThreadID, "thread-C")
    XCTAssertTrue(model.projects.contains(where: { $0.id == "C" }))
    await model.disconnect()
  }

  func testOverviewCatalogFailureRetainsPriorGroupsAndReportsStale() async throws {
    let service = FakeRemoteService(projectErrorCalls: [3])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    await model.refreshAgentOverview()
    let priorGroups = model.agentOverviewGroups
    XCTAssertEqual(priorGroups.count, 2)

    await model.refreshAgentOverview()
    XCTAssertEqual(model.agentOverviewGroups, priorGroups)
    XCTAssertTrue(model.agentOverviewIsStale)
    XCTAssertNotNil(model.agentOverviewError)
    XCTAssertFalse(model.loadingAgentOverview)
    await model.disconnect()
  }

  func testOverlappingOverviewRefreshesCoalesceAndRunFinalRefresh() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(projectGate: gate, projectGateAtCall: 2)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    let first = Task { await model.refreshAgentOverview() }
    await gate.waitUntilEntered()
    let second = Task { await model.refreshAgentOverview() }
    await gate.open()
    await first.value
    await second.value
    let projectCalls = await service.projectCallCount()
    XCTAssertEqual(projectCalls, 3)
    XCTAssertEqual(model.agentOverviewGroups.count, 2)
    XCTAssertFalse(model.loadingAgentOverview)
    await model.disconnect()
  }

  func testOverviewClearsWhenReconnectResolvesDifferentHostIdentity() async throws {
    let first = FakeRemoteService(serverIDValue: "host-A")
    let second = FakeRemoteService(serverIDValue: "host-B")
    let factory = FakeConnectionFactory(
      connectServices: [first], reconnectServices: [second])
    let model = OesapModel(connectionFactory: factory)
    await model.connect(.empty)
    await model.refreshAgentOverview()
    XCTAssertEqual(model.agentOverviewGroups.count, 2)

    await model.reconnect()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertTrue(model.agentOverviewGroups.isEmpty)
    XCTAssertFalse(model.agentOverviewIsStale)
    await model.disconnect()
  }

  func testProviderUsageRetainsLastKnownValuesOnRPCFailure() async throws {
    let service = FakeRemoteService(
      usageSupported: true, usageSnapshot: usageSnapshot(providerID: "codex"),
      usageErrorCalls: [2])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    let initialLoaded = await eventually { model.providerUsageProviders.map(\.id) == ["codex"] }
    XCTAssertTrue(initialLoaded)
    XCTAssertEqual(model.providerUsageFetchedAt, Date(timeIntervalSince1970: 100))
    XCTAssertFalse(model.providerUsageIsStale)

    await model.refreshProviderUsage()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.providerUsageProviders.map(\.id), ["codex"])
    XCTAssertTrue(model.providerUsageIsStale)
    XCTAssertNotNil(model.providerUsageError)
    await model.disconnect()
  }

  func testProviderUsageClearsBeforeDifferentHostRefreshCompletes() async throws {
    let gate = TestGate()
    let first = FakeRemoteService(
      serverIDValue: "host-A", usageSupported: true,
      usageSnapshot: usageSnapshot(providerID: "codex"))
    let second = FakeRemoteService(
      serverIDValue: "host-B", usageSupported: true,
      usageSnapshot: usageSnapshot(providerID: "claude"), usageGate: gate)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [first], reconnectServices: [second]))
    await model.connect(.empty)
    let firstHostLoaded = await eventually { model.providerUsageProviders.map(\.id) == ["codex"] }
    XCTAssertTrue(firstHostLoaded)

    await model.reconnect()
    await gate.waitUntilEntered()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertTrue(model.providerUsageProviders.isEmpty)
    XCTAssertNil(model.providerUsageFetchedAt)
    await gate.open()
    let secondHostLoaded = await eventually { model.providerUsageProviders.map(\.id) == ["claude"] }
    XCTAssertTrue(secondHostLoaded)
    await model.disconnect()
  }

  func testDifferentHostClearsCachedContextEvenWhenWorkspaceReloadFails() async throws {
    let first = FakeRemoteService(
      serverIDValue: "host-A",
      contextReport: RemoteContextUsage(usedTokens: 20, maxTokens: 100))
    let second = FakeRemoteService(
      projectsError: RemoteServiceError.unavailable("Project catalog unavailable"),
      serverIDValue: "host-B")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [first], reconnectServices: [second]))
    await model.connect(.empty)
    XCTAssertEqual(model.contextUsage(for: "thread-A")?.usedTokens, 20)

    await model.reconnect()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertNil(model.contextUsage(for: "thread-A"))
    XCTAssertNotNil(model.workspaceError)
    await model.disconnect()
  }

  func testLiveContextUpdateWinsOverOlderInFlightSnapshot() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(
      contextReport: RemoteContextUsage(usedTokens: 20, maxTokens: 100),
      contextGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let watching = Task { await model.watchTimeline(threadID: "thread-A") }
    await gate.waitUntilEntered()

    await service.emit(
      .contextUsage(RemoteContextUsage(usedTokens: 30, maxTokens: nil)))
    let liveUpdated = await eventually { model.contextUsage(for: "thread-A")?.usedTokens == 30 }
    XCTAssertTrue(liveUpdated)
    XCTAssertEqual(model.contextUsage(for: "thread-A")?.maxTokens, 100)
    await gate.open()
    let refreshFinished = await eventually { !model.loadingContextUsage }
    XCTAssertTrue(refreshFinished)
    XCTAssertEqual(model.contextUsage(for: "thread-A")?.usedTokens, 30)
    watching.cancel()
    await watching.value
    await model.disconnect()
  }

  func testOlderContextRefreshFailureDoesNotOverrideNewLiveReport() async throws {
    let gate = TestGate()
    let service = FakeRemoteService(
      contextReport: RemoteContextUsage(usedTokens: 20, maxTokens: 100),
      contextGate: gate,
      contextError: RemoteServiceError.unavailable("stale request failed"))
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let watching = Task { await model.watchTimeline(threadID: "thread-A") }
    await gate.waitUntilEntered()

    await service.emit(
      .contextUsage(RemoteContextUsage(usedTokens: 30, maxTokens: 100)))
    let liveUpdated = await eventually { model.contextUsage(for: "thread-A")?.usedTokens == 30 }
    XCTAssertTrue(liveUpdated)
    await gate.open()
    let refreshFinished = await eventually { !model.loadingContextUsage }
    XCTAssertTrue(refreshFinished)
    XCTAssertNil(model.contextUsageError)
    watching.cancel()
    await watching.value
    await model.disconnect()
  }

  func testAuthoritativePartialContextSnapshotReplacesPriorDenominator() async throws {
    let service = FakeRemoteService(
      contextReport: RemoteContextUsage(usedTokens: 30, maxTokens: nil),
      initialThreadContext: RemoteContextUsage(usedTokens: 20, maxTokens: 100))
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    XCTAssertEqual(model.contextUsage(for: "thread-A")?.fractionUsed, 0.2)
    model.selectThread("thread-A")

    await model.refreshContextUsage(threadID: "thread-A")
    XCTAssertEqual(model.contextUsage(for: "thread-A")?.usedTokens, 30)
    XCTAssertNil(model.contextUsage(for: "thread-A")?.maxTokens)
    XCTAssertNil(model.contextUsage(for: "thread-A")?.fractionUsed)
    await model.disconnect()
  }

  private func usageSnapshot(providerID: String) -> RemoteProviderUsageSnapshot {
    RemoteProviderUsageSnapshot(
      fetchedAt: Date(timeIntervalSince1970: 100),
      providers: [
        RemoteProviderUsage(
          id: providerID, displayName: providerID, status: .available,
          planLabel: nil, sourceLabel: nil, fetchedAt: nil, nextRefreshAt: nil,
          windows: [], balances: [], details: [], error: nil)
      ])
  }

  private func isolatedAgentStore() -> AgentConfigurationStore {
    let defaults = UserDefaults(suiteName: "oesap-tests-\(UUID().uuidString)")!
    return AgentConfigurationStore(defaults: defaults)
  }

  func testConnectionFailurePreservesActionableDiagnostics() async {
    let detail =
      "The host could not be reached. Check the host address and VPN. [connect; NSURLErrorDomain:-1004]"
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [], connectError: .connectionLost(detail)))

    await model.connect(.empty)

    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertEqual(model.connectError, detail)
    XCTAssertEqual(model.instanceError, detail)
  }

  func testReturningToSelectedProjectAndThreadPreservesCachedTimelineAndSubscription() async {
    let service = FakeRemoteService()
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.startTimelineObservation(threadID: "thread-A")
    let loaded = await eventually { !model.messages.isEmpty && !model.loadingHistory }
    XCTAssertTrue(loaded)
    let messages = model.messages
    let revision = model.timelineStructureRevision
    model.setDraft("Keep this draft", for: "thread-A")

    await model.selectProject("A")
    model.selectThread("thread-A")
    model.startTimelineObservation(threadID: "thread-A")

    XCTAssertEqual(model.messages, messages)
    XCTAssertEqual(model.timelineStructureRevision, revision)
    XCTAssertEqual(model.draft(for: "thread-A"), "Keep this draft")
    let subscriptions = await service.subscriptionCount()
    XCTAssertEqual(subscriptions, 1)
    await model.disconnect()
  }

  func testForegroundKeepsHealthyConnectionAndCachedTimeline() async {
    let service = FakeRemoteService()
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    await model.start()
    model.selectThread("thread-A")
    model.startTimelineObservation(threadID: "thread-A")
    let loaded = await eventually { !model.messages.isEmpty }
    XCTAssertTrue(loaded)
    let messages = model.messages
    let revision = model.timelineStructureRevision

    model.appDidEnterBackground()
    await model.appDidBecomeActive()

    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.messages, messages)
    XCTAssertEqual(model.timelineStructureRevision, revision)
    let closed = await service.isClosed()
    XCTAssertFalse(closed)
    let subscriptions = await service.subscriptionCount()
    XCTAssertEqual(subscriptions, 1)
    await model.disconnect()
  }

  func testForegroundRecoversFailedSessionAndRestoresStoreOwnedTimeline() async {
    let first = FakeRemoteService()
    let second = FakeRemoteService(historyText: "Recovered")
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [first], reconnectServices: [second]))
    await model.connect(.empty)
    await model.start()
    model.selectThread("thread-A")
    model.startTimelineObservation(threadID: "thread-A")
    let loaded = await eventually { !model.messages.isEmpty }
    XCTAssertTrue(loaded)
    model.setDraft("Keep this draft", for: "thread-A")

    await first.emitDisconnect("Session expired")
    let disconnected = await eventually { model.connectionState == .disconnected }
    XCTAssertTrue(disconnected)

    model.appDidEnterBackground()
    await model.appDidBecomeActive()

    XCTAssertEqual(model.connectionState, .connected)
    let restored = await eventually { model.messages.first?.text == "Recovered" }
    XCTAssertTrue(restored)
    XCTAssertEqual(model.draft(for: "thread-A"), "Keep this draft")
    let subscriptions = await second.subscriptionCount()
    XCTAssertEqual(subscriptions, 1)
    await model.disconnect()
  }

  func testConcurrentForegroundChecksShareExistingSessionProbe() async {
    let gate = TestGate()
    let service = FakeRemoteService(projectGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    await model.start()
    model.appDidEnterBackground()
    let first = Task { await model.appDidBecomeActive() }
    await gate.waitUntilEntered()
    await model.appDidBecomeActive()
    await gate.open()
    await first.value
    let calls = await service.projectCallCount()
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(model.connectionState, .connected)
    await model.disconnect()
  }

  func testConcurrentWorkspaceRefreshesShareOneRequest() async {
    let gate = TestGate()
    let service = FakeRemoteService(projectGate: gate)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    let cachedProjects = model.projects
    let first = Task { await model.refreshWorkspace() }
    await gate.waitUntilEntered()
    let second = Task { await model.refreshWorkspace() }
    await Task.yield()
    XCTAssertEqual(model.projects, cachedProjects)
    await gate.open()
    await first.value
    await second.value
    let calls = await service.projectCallCount()
    XCTAssertEqual(calls, 2)
    await model.disconnect()
  }

  func testAuthenticationFailureDoesNotRetry() async {
    let factory = FakeConnectionFactory(
      connectServices: [], connectError: .authentication("Rejected"))
    let model = OesapModel(connectionFactory: factory)
    await model.connect(.empty)
    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertEqual(model.connectError, "Rejected")
    let attempts = await factory.connectionAttemptCount()
    XCTAssertEqual(attempts, 1)
    XCTAssertNil(model.connectionRetryDetails)
  }

  func testReconnectFailureKeepsDiagnosticsInWorkspaceAndPreservesDraft() async {
    let detail =
      "TLS verification failed. Check the host certificate. [connect; NSURLErrorDomain:-1202]"
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(
        connectServices: [FakeRemoteService()], reconnectError: .connectionLost(detail)))
    await model.connect(.empty)
    model.selectThread("thread-A")
    model.setDraft("Keep my draft", for: "thread-A")

    await model.reconnect()

    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertEqual(model.connectError, detail)
    XCTAssertTrue(model.workspaceError?.contains(detail) == true)
    XCTAssertEqual(model.draft(for: "thread-A"), "Keep my draft")
    await model.disconnect()
  }

  func testTimelineFailureRetainsSourceDiagnosticWithoutConnectionEvent() async {
    let detail =
      "Network interrupted. Reconnect. Phase: receive · Cause: connectionLost · NSURLErrorDomain -1005"
    let service = FakeRemoteService()
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let watch = Task { await model.watchTimeline(threadID: "thread-A") }
    let subscribed = await eventually { await service.subscriptionCount() == 1 }
    XCTAssertTrue(subscribed)

    await service.failTimeline(.connectionLost(detail))
    let disconnected = await eventually { model.connectionState == .disconnected }
    XCTAssertTrue(disconnected)
    XCTAssertTrue(model.connectError?.contains(detail) == true)
    XCTAssertTrue(model.workspaceError?.contains(detail) == true)
    await watch.value
    await model.disconnect()
  }

  func testEmptyAndFailedProjectLoadsHaveDistinctStates() async throws {
    let empty = FakeRemoteService(projects: [])
    let emptyModel = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [empty]))
    await emptyModel.connect(.empty)
    XCTAssertEqual(emptyModel.connectionState, .connected)
    XCTAssertTrue(emptyModel.projects.isEmpty)
    XCTAssertNil(emptyModel.workspaceError)
    await emptyModel.disconnect()

    let failing = FakeRemoteService(
      projectsError: RemoteServiceError.connectionLost("fixture failure"))
    let failedModel = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [failing]))
    await failedModel.connect(.empty)
    XCTAssertEqual(failedModel.connectionState, .disconnected)
    XCTAssertNotNil(failedModel.workspaceError)
    XCTAssertFalse(failedModel.loadingProjects)
    await failedModel.disconnect()
  }

  func testSelectedProjectRequestFailureKeepsHostConnectedAndOverviewAvailable() async throws {
    UserDefaults.standard.set("B", forKey: "selectedProjectID")
    let service = FakeRemoteService(threadErrorForB: true)
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]))

    await model.connect(.empty)
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.selectedProjectID, "B")
    XCTAssertFalse(model.loadingThreads)
    XCTAssertNotNil(model.workspaceError)

    await model.refreshAgentOverview()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.agentOverviewGroups.map(\.project.id), ["A", "B"])
    XCTAssertEqual(model.agentOverviewGroups[0].threads.map(\.id), ["thread-A"])
    XCTAssertNotNil(model.agentOverviewGroups[1].error)
    XCTAssertTrue(model.agentOverviewIsStale)
    await model.disconnect()
  }

  func testProjectCatalogRequestFailureDoesNotDisconnectHealthyHost() async throws {
    let service = FakeRemoteService(projectErrorCalls: [1])
    let model = OesapModel(
      connectionFactory: FakeConnectionFactory(connectServices: [service]))

    await model.connect(.empty)
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertTrue(model.projects.isEmpty)
    XCTAssertNotNil(model.workspaceError)
    XCTAssertFalse(model.loadingProjects)

    await model.refreshWorkspace()
    XCTAssertEqual(model.projects.map(\.id), ["A", "B"])
    XCTAssertNil(model.workspaceError)
    await model.disconnect()
  }

  func testSubscriptionClosesOnLossAndReconnectStartsNewObservation() async throws {
    let first = FakeRemoteService()
    let second = FakeRemoteService()
    let factory = FakeConnectionFactory(connectServices: [first], reconnectServices: [second])
    let model = OesapModel(connectionFactory: factory)
    await model.connect(.empty)
    model.selectThread("thread-A")
    let firstWatch = Task { await model.watchTimeline(threadID: "thread-A") }
    let firstSubscribed = await eventually { await first.subscriptionCount() == 1 }
    XCTAssertTrue(firstSubscribed)

    await first.emitDisconnect("fixture loss")
    let disconnected = await eventually { model.connectionState == .disconnected }
    let firstReleased = await eventually { await first.subscriptionCount() == 0 }
    XCTAssertTrue(disconnected)
    XCTAssertTrue(firstReleased)
    XCTAssertTrue(model.connectError?.contains("fixture loss") == true)
    XCTAssertTrue(model.workspaceError?.contains("fixture loss") == true)
    await firstWatch.value

    await model.reconnect()
    XCTAssertEqual(model.connectionState, .connected)
    let secondWatch = Task { await model.watchTimeline(threadID: "thread-A") }
    let secondSubscribed = await eventually { await second.subscriptionCount() == 1 }
    XCTAssertTrue(secondSubscribed)
    await model.disconnect()
    let secondReleased = await eventually { await second.subscriptionCount() == 0 }
    XCTAssertTrue(secondReleased)
    await secondWatch.value
  }

  func testLargeTimelineDeltasPreserveRowsAndDoNotInvalidateStructure() async throws {
    let history = (0..<1_000).map { index in
      RemoteMessage(id: "row-\(index)", author: .agent, text: "Message \(index)", timestamp: nil)
    }
    let service = FakeRemoteService(
      historyMessages: history,
      olderMessages: [.init(id: "older", author: .agent, text: "Earlier", timestamp: nil)])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let watching = Task { await model.watchTimeline(threadID: "thread-A") }
    let loaded = await eventually { model.messages.count == 1_000 && !model.loadingHistory }
    XCTAssertTrue(loaded)
    let structureRevision = model.timelineStructureRevision

    for sequence in 6..<1_006 {
      await service.emit(
        .message(
          .init(id: "row-999", author: .agent, text: ".", timestamp: nil),
          cursor: .init(epoch: "e1", sequence: sequence), isDelta: true))
    }
    let streamed = await eventually {
      model.messages.last?.text.count == "Message 999".count + 1_000
    }
    XCTAssertTrue(streamed)
    XCTAssertEqual(model.timelineStructureRevision, structureRevision)
    XCTAssertEqual(Array(model.messages.dropLast()), Array(history.dropLast()))

    await model.loadOlderMessages(threadID: "thread-A")
    XCTAssertEqual(model.messages.count, 1_001)
    XCTAssertGreaterThan(model.timelineStructureRevision, structureRevision)
    await service.emit(
      .message(
        .init(id: "row-0", author: .agent, text: " updated", timestamp: nil),
        cursor: .init(epoch: "e1", sequence: 1_006), isDelta: true))
    let updatedAfterPrepend = await eventually { model.messages[1].text == "Message 0 updated" }
    XCTAssertTrue(updatedAfterPrepend, "History insertion must rebuild the message lookup")
    XCTAssertEqual(model.messages.first?.text, "Earlier")

    await model.disconnect()
    await watching.value
    XCTAssertTrue(model.messages.isEmpty)
  }

  func testSnapshotWatermarkAndLiveDeltaMerge() async throws {
    let service = FakeRemoteService()
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let watching = Task { await model.watchTimeline(threadID: "thread-A") }
    let snapshotLoaded = await eventually {
      await service.subscriptionCount() == 1 && !model.loadingHistory
    }
    XCTAssertTrue(snapshotLoaded)

    let snapshotRow = RemoteMessage(id: "assistant", author: .agent, text: "Hi", timestamp: nil)
    await service.emit(
      .message(snapshotRow, cursor: .init(epoch: "e1", sequence: 5), isDelta: true))
    await service.emit(
      .message(
        .init(id: "assistant", author: .agent, text: " there", timestamp: nil),
        cursor: .init(epoch: "e1", sequence: 6), isDelta: true))
    let deltaMerged = await eventually { model.messages.first?.text == "Hi there" }
    XCTAssertTrue(deltaMerged)
    await model.disconnect()
    await watching.value
  }

  func testNewLiveRowPreservesProjectedToolOrderDespiteTimestamps() async throws {
    let tool = RemoteToolCall(
      callID: "call-1", turnID: "turn-A", name: "Bash", title: "Shell", status: .running)
    let history = [
      RemoteMessage(
        id: tool.rowID, author: .agent, text: "Shell", timestamp: Date(timeIntervalSince1970: 300),
        toolCall: tool),
      RemoteMessage(
        id: "reply", author: .agent, text: "I found it", timestamp: Date(timeIntervalSince1970: 200)
      ),
    ]
    let service = FakeRemoteService(historyMessages: history)
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let watching = Task { await model.watchTimeline(threadID: "thread-A") }
    let loaded = await eventually { model.messages.map(\.id) == [tool.rowID, "reply"] }
    XCTAssertTrue(loaded)

    await service.emit(
      .message(
        .init(
          id: "next", author: .agent, text: "Done",
          timestamp: Date(timeIntervalSince1970: 100)),
        cursor: .init(epoch: "e1", sequence: 6), isDelta: false))
    let appended = await eventually { model.messages.map(\.id) == [tool.rowID, "reply", "next"] }
    XCTAssertTrue(appended)
    await model.disconnect()
    await watching.value
  }

  func testOlderToolPageCannotDowngradeLoadedFinalRevision() async throws {
    let finalTool = RemoteToolCall(
      callID: "shared", turnID: "turn-B", name: "Bash", title: "Shell", status: .completed)
    let oldTool = RemoteToolCall(
      callID: "shared", turnID: "turn-B", name: "Bash", title: "Shell", status: .running)
    let otherTurn = RemoteToolCall(
      callID: "shared", turnID: "turn-A", name: "Read", title: "Read", status: .completed)
    let service = FakeRemoteService(
      historyMessages: [
        .init(
          id: finalTool.rowID, author: .agent, text: "Shell", timestamp: nil,
          toolCall: finalTool)
      ],
      olderMessages: [
        .init(
          id: otherTurn.rowID, author: .agent, text: "Read", timestamp: nil,
          toolCall: otherTurn),
        .init(
          id: oldTool.rowID, author: .agent, text: "Shell", timestamp: nil,
          toolCall: oldTool),
      ])
    let model = OesapModel(connectionFactory: FakeConnectionFactory(connectServices: [service]))
    await model.connect(.empty)
    model.selectThread("thread-A")
    let watching = Task { await model.watchTimeline(threadID: "thread-A") }
    let loaded = await eventually { model.messages.first?.toolCall?.status == .completed }
    XCTAssertTrue(loaded)
    await model.loadOlderMessages(threadID: "thread-A")

    XCTAssertEqual(model.messages.map(\.id), [otherTurn.rowID, finalTool.rowID])
    XCTAssertEqual(model.messages.last?.toolCall?.status, .completed)
    await model.disconnect()
    await watching.value
  }

  func testOldTimelineHistoryCannotOverwriteSameThreadAfterReconnect() async throws {
    let gate = TestGate()
    let first = FakeRemoteService(historyGate: gate, historyText: "old")
    let second = FakeRemoteService(historyText: "new")
    let factory = FakeConnectionFactory(connectServices: [first], reconnectServices: [second])
    let model = OesapModel(connectionFactory: factory)
    await model.connect(.empty)
    model.selectThread("thread-A")
    let oldWatch = Task { await model.watchTimeline(threadID: "thread-A") }
    await gate.waitUntilEntered()

    await model.reconnect()
    let newWatch = Task { await model.watchTimeline(threadID: "thread-A") }
    let newHistoryLoaded = await eventually { model.messages.first?.text == "new" }
    XCTAssertTrue(newHistoryLoaded)
    await gate.open()
    await oldWatch.value
    XCTAssertEqual(model.messages.first?.text, "new")
    await model.disconnect()
    await newWatch.value
  }

  private func eventually(_ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<100 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private func sessionSettingsFixture() -> RemoteAgentSettings {
  RemoteAgentSettings(
    agentID: "thread-A", provider: "codex", cwd: "/fixture/project",
    modelID: "model-one", thinkingOptionID: "medium",
    effectiveThinkingOptionID: "medium",
    currentModeID: "auto",
    availableModes: [
      RemoteAgentMode(id: "auto", label: "Default Permissions", description: "Ask as needed."),
      RemoteAgentMode(id: "full-access", label: "Full Access", description: "Do not ask."),
    ],
    models: [
      RemoteAgentModel(
        id: "model-one", label: "Model One", isDefault: true,
        thinkingOptions: [
          RemoteThinkingOption(id: "medium", label: "Medium", description: nil, isDefault: true),
          RemoteThinkingOption(id: "high", label: "High", description: nil, isDefault: false),
        ], defaultThinkingOptionID: "medium"),
      RemoteAgentModel(
        id: "model-two", label: "Model Two", isDefault: false,
        thinkingOptions: [
          RemoteThinkingOption(id: "high", label: "High", description: nil, isDefault: true),
          RemoteThinkingOption(id: "max", label: "Max", description: nil, isDefault: false),
        ], defaultThinkingOptionID: "high"),
    ], canApply: true, supportsThinking: true, status: "idle")
}

private actor TestGate {
  private var waiter: CheckedContinuation<Void, Never>?
  private var entryWaiter: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiter = continuation
      entryWaiter?.resume()
      entryWaiter = nil
    }
  }

  func waitUntilEntered() async {
    guard waiter == nil else { return }
    await withCheckedContinuation { entryWaiter = $0 }
  }

  func open() {
    isOpen = true
    waiter?.resume()
    waiter = nil
  }
}

private actor FakeConnectionFactory: OesapConnectionFactory {
  private var connectServices: [FakeRemoteService]
  private var reconnectServices: [FakeRemoteService]
  private let connectGate: TestGate?
  private let connectError: RemoteServiceError?
  private let reconnectError: RemoteServiceError?
  private var active: FakeRemoteService?
  private var savedInstances: [SavedPaseoInstance]
  private var currentInstanceID: String?
  private var instanceServices: [String: FakeRemoteService]
  private var generation = 0
  private var connectCount = 0
  private var connectionAttempts = 0
  private var overviewInstances: Set<String> = []
  private var overviewConnectionCalls: [String] = []

  func overviewCalls() -> [String] { overviewConnectionCalls }

  func connectForOverview(instanceID: String) async throws -> any OesapRemoteService {
    overviewConnectionCalls.append(instanceID)
    guard savedInstances.contains(where: { $0.id == instanceID }),
      let service = instanceServices[instanceID]
    else { throw RemoteServiceError.unavailable("Unknown overview instance") }
    await service.reopen()
    if instanceID != currentInstanceID { overviewInstances.insert(instanceID) }
    return service
  }

  func disconnectOverviewService(instanceID: String) async {
    guard overviewInstances.remove(instanceID) != nil else { return }
    if instanceID != currentInstanceID { await instanceServices[instanceID]?.disconnect() }
  }

  func disconnectOverviewServices() async {
    let instances = overviewInstances
    overviewInstances = []
    for id in instances where id != currentInstanceID { await instanceServices[id]?.disconnect() }
  }

  func connectionAttemptCount() -> Int { connectionAttempts }

  init(
    connectServices: [FakeRemoteService], reconnectServices: [FakeRemoteService] = [],
    connectGate: TestGate? = nil, initiallySaved: Bool = false,
    initiallySavedInstances: [SavedPaseoInstance] = [], activeInstanceID: String? = nil,
    instanceServices: [String: FakeRemoteService] = [:],
    connectError: RemoteServiceError? = nil, reconnectError: RemoteServiceError? = nil
  ) {
    let instances =
      initiallySaved && initiallySavedInstances.isEmpty
      ? [SavedPaseoInstance(id: "saved-instance", name: "Saved connection", subtitle: "")]
      : initiallySavedInstances
    let currentID = activeInstanceID ?? instances.first?.id
    let activeService = currentID.flatMap { instanceServices[$0] }

    self.connectServices = connectServices
    self.reconnectServices = reconnectServices
    self.connectGate = connectGate
    self.connectError = connectError
    self.reconnectError = reconnectError
    self.savedInstances = instances
    self.currentInstanceID = currentID
    self.instanceServices = instanceServices
    self.active = activeService
  }

  func savedConnectionExists() async -> Bool { !savedInstances.isEmpty }
  func listSavedInstances() async throws -> [SavedPaseoInstance] { savedInstances }
  func activeInstanceID() async throws -> String? { currentInstanceID }

  func selectSavedInstance(id: String) async throws -> any OesapRemoteService {
    guard savedInstances.contains(where: { $0.id == id }) else {
      throw RemoteServiceError.unavailable("Unknown saved instance")
    }
    generation += 1
    let previousID = currentInstanceID
    let previousService = active
    currentInstanceID = id
    active = nil
    if previousID != id { await previousService?.disconnect() }
    guard let service = instanceServices[id] else {
      throw RemoteServiceError.unavailable("The saved instance has no fixture service")
    }
    await service.reopen()
    overviewInstances.remove(id)
    active = service
    return service
  }

  func removeSavedInstance(id: String) async throws {
    generation += 1
    savedInstances.removeAll { $0.id == id }
    await disconnectOverviewService(instanceID: id)
    instanceServices[id] = nil
    if currentInstanceID == id {
      await active?.disconnect()
      active = nil
      currentInstanceID = nil
    }
  }

  func connect(_ connection: RemoteConnection) async throws -> any OesapRemoteService {
    connectionAttempts += 1
    generation += 1
    let attempt = generation
    if let connectError { throw connectError }
    let service = connectServices.removeFirst()
    await connectGate?.wait()
    if Task.isCancelled || attempt != generation {
      await service.disconnect()
      throw CancellationError()
    }
    connectCount += 1
    let id = "connected-instance-\(connectCount)"
    savedInstances.append(
      SavedPaseoInstance(
        id: id,
        name: connection.name.isEmpty ? "Paseo" : connection.name,
        subtitle: connection.endpoint))
    currentInstanceID = id
    active = service
    instanceServices[id] = service
    return service
  }

  func reconnect() async throws -> any OesapRemoteService {
    generation += 1
    if let reconnectError { throw reconnectError }
    let service = reconnectServices.removeFirst()
    await active?.disconnect()
    active = service
    if let currentInstanceID { instanceServices[currentInstanceID] = service }
    return service
  }

  func disconnect() async throws {
    generation += 1
    await active?.disconnect()
    if let currentInstanceID {
      savedInstances.removeAll { $0.id == currentInstanceID }
      instanceServices[currentInstanceID] = nil
    }
    active = nil
    currentInstanceID = nil
  }
}

private actor FakeRemoteService: OesapRemoteService {
  struct SentAgentMessage: Sendable, Equatable {
    let agentID: String
    let text: String
    let messageID: String
    let behavior: RemoteActiveTurnBehavior
    let images: [RemoteDraftImage]
  }

  private let openAgentGate: TestGate?
  private let openPermissions: [RemotePermission]
  private let endlessOlderPages: Bool
  private var olderPageCalls = 0
  private var permissionAnswers = 0
  private let projectsValue: [RemoteProject]
  private var projectsError: Error?
  private let projectsAfterFirstCall: [RemoteProject]?
  private let projectErrorCalls: Set<Int>
  private let projectGate: TestGate?
  private let projectGateAtCall: Int
  private let threadGateForA: TestGate?
  private let sendGate: TestGate?
  private let sendGateAgentID: String?
  private let historyGate: TestGate?
  private let historyText: String
  private let historyMessages: [RemoteMessage]?
  private let olderMessages: [RemoteMessage]?
  private let failsSending: Bool
  private let receiptSupport: Bool
  private let failSendCalls: Set<Int>
  private let stopGate: TestGate?
  private let stopSnapshot: RemoteAgentControlSnapshot?
  private let stopError: Error?
  private let initialThreadState: RemoteThread.State
  private let creationGate: TestGate?
  private let failFirstCreation: Bool
  private let failFirstCreationDefinitively: Bool
  private let promptAccepted: Bool
  private let threadErrorForB: Bool
  private let serverIDValue: String?
  private let usageSupported: Bool
  private let usageSnapshot: RemoteProviderUsageSnapshot?
  private let usageErrorCalls: Set<Int>
  private let usageGate: TestGate?
  private let usageGateAtCall: Int
  private let contextReport: RemoteContextUsage?
  private let initialThreadContext: RemoteContextUsage?
  private let contextGate: TestGate?
  private let contextError: Error?
  private let threadCWD: String?
  private let imageReadGate: TestGate?
  private let initialSettings: RemoteAgentSettings?
  private let settingsGate: TestGate?
  private let settingsGateAtCall: Int
  private let settingsApplyGate: TestGate?
  private let settingsApplyError: Error?
  private let normalizedThinkingOptionID: String?
  private var settingsByAgentID: [String: RemoteAgentSettings] = [:]
  private var settingsCalls = 0
  private var settingsApplyCalls = 0
  private var thinkingApplyCalls = 0
  private var modeApplyCalls = 0
  private var imageReadTargets: [(cwd: String, path: String, maxBytes: Int)] = []
  private var usageCalls = 0
  private var submittedCreations: [RemoteNewThreadIntent] = []
  private var projectCalls = 0
  private var threadACalls = 0
  private var threadBCalls = 0
  private var timelineContinuations:
    [UUID: AsyncThrowingStream<RemoteTimelineUpdate, Error>.Continuation] = [:]
  private var connectionContinuation: AsyncStream<RemoteConnectionEvent>.Continuation?
  private var pendingDisconnectReason: String?
  private var closed = false
  private var sentAgentMessages: [SentAgentMessage] = []
  private var stopCalls = 0

  init(
    projects: [RemoteProject] = [
      .init(id: "A", name: "Project A", subtitle: nil),
      .init(id: "B", name: "Project B", subtitle: nil),
    ], projectsError: Error? = nil,
    projectsAfterFirstCall: [RemoteProject]? = nil,
    projectErrorCalls: Set<Int> = [], projectGate: TestGate? = nil,
    projectGateAtCall: Int = 2,
    threadGateForA: TestGate? = nil, sendGate: TestGate? = nil,
    sendGateAgentID: String? = nil,
    historyGate: TestGate? = nil, historyText: String = "Hi",
    historyMessages: [RemoteMessage]? = nil,
    olderMessages: [RemoteMessage]? = nil,
    failsSending: Bool = false, receiptSupport: Bool = true,
    failSendCalls: Set<Int> = [], stopGate: TestGate? = nil,
    stopSnapshot: RemoteAgentControlSnapshot? = nil, stopError: Error? = nil,
    initialThreadState: RemoteThread.State = .idle,
    creationGate: TestGate? = nil,
    failFirstCreation: Bool = false, failFirstCreationDefinitively: Bool = false,
    promptAccepted: Bool = true, threadErrorForB: Bool = false,
    serverIDValue: String? = "fixture-host", usageSupported: Bool = false,
    usageSnapshot: RemoteProviderUsageSnapshot? = nil,
    usageErrorCalls: Set<Int> = [], usageGate: TestGate? = nil,
    usageGateAtCall: Int = 1, contextReport: RemoteContextUsage? = nil,
    initialThreadContext: RemoteContextUsage? = nil, contextGate: TestGate? = nil,
    contextError: Error? = nil, threadCWD: String? = nil,
    imageReadGate: TestGate? = nil,
    initialSettings: RemoteAgentSettings? = nil,
    settingsGate: TestGate? = nil, settingsGateAtCall: Int = 1,
    settingsApplyGate: TestGate? = nil, settingsApplyError: Error? = nil,
    normalizedThinkingOptionID: String? = nil, openAgentGate: TestGate? = nil,
    openPermissions: [RemotePermission] = [], endlessOlderPages: Bool = false
  ) {
    self.openAgentGate = openAgentGate
    self.openPermissions = openPermissions
    self.endlessOlderPages = endlessOlderPages
    self.projectsValue = projects
    self.projectsError = projectsError
    self.projectsAfterFirstCall = projectsAfterFirstCall
    self.projectErrorCalls = projectErrorCalls
    self.projectGate = projectGate
    self.projectGateAtCall = projectGateAtCall
    self.threadGateForA = threadGateForA
    self.sendGate = sendGate
    self.sendGateAgentID = sendGateAgentID
    self.historyGate = historyGate
    self.historyText = historyText
    self.historyMessages = historyMessages
    self.olderMessages = olderMessages
    self.failsSending = failsSending
    self.receiptSupport = receiptSupport
    self.failSendCalls = failSendCalls
    self.stopGate = stopGate
    self.stopSnapshot = stopSnapshot
    self.stopError = stopError
    self.initialThreadState = initialThreadState
    self.creationGate = creationGate
    self.failFirstCreation = failFirstCreation
    self.failFirstCreationDefinitively = failFirstCreationDefinitively
    self.promptAccepted = promptAccepted
    self.threadErrorForB = threadErrorForB
    self.serverIDValue = serverIDValue
    self.usageSupported = usageSupported
    self.usageSnapshot = usageSnapshot
    self.usageErrorCalls = usageErrorCalls
    self.usageGate = usageGate
    self.usageGateAtCall = usageGateAtCall
    self.contextReport = contextReport
    self.initialThreadContext = initialThreadContext
    self.contextGate = contextGate
    self.contextError = contextError
    self.threadCWD = threadCWD
    self.imageReadGate = imageReadGate
    self.initialSettings = initialSettings
    self.settingsGate = settingsGate
    self.settingsGateAtCall = settingsGateAtCall
    self.settingsApplyGate = settingsApplyGate
    self.settingsApplyError = settingsApplyError
    self.normalizedThinkingOptionID = normalizedThinkingOptionID
  }

  func serverID() async -> String? { serverIDValue }
  func supportsNewThreads() async -> Bool { true }
  func supportsProviderUsage() async -> Bool { usageSupported }
  func supportsAgentRequestReceipts() async -> Bool { receiptSupport }

  func providerUsage() async throws -> RemoteProviderUsageSnapshot {
    usageCalls += 1
    if usageCalls == usageGateAtCall { await usageGate?.wait() }
    if usageErrorCalls.contains(usageCalls) {
      throw RemoteServiceError.unavailable("Usage request failed")
    }
    return usageSnapshot ?? RemoteProviderUsageSnapshot(fetchedAt: nil, providers: [])
  }

  func contextUsage(agentID: String) async throws -> RemoteContextUsage? {
    await contextGate?.wait()
    if let contextError { throw contextError }
    return contextReport
  }

  func agentSettings(agentID: String) async throws -> RemoteAgentSettings {
    settingsCalls += 1
    if settingsCalls == settingsGateAtCall { await settingsGate?.wait() }
    guard var settings = settingsByAgentID[agentID] ?? initialSettings else {
      throw RemoteServiceError.unavailable("Session settings are unavailable")
    }
    settings.agentID = agentID
    return settings
  }

  func applyAgentSettings(
    agentID: String, modelID: String?, thinkingOptionID: String?, modeID: String?
  ) async throws -> RemoteAgentSettingsApplyResult {
    settingsApplyCalls += 1
    await settingsApplyGate?.wait()
    var settings = try await agentSettings(agentID: agentID)
    settings.modelID = modelID
    if let modeID { settings.currentModeID = modeID }
    if let settingsApplyError {
      settingsByAgentID[agentID] = settings
      throw settingsApplyError
    }
    settings.thinkingOptionID = normalizedThinkingOptionID ?? thinkingOptionID
    settings.effectiveThinkingOptionID = settings.thinkingOptionID
    settingsByAgentID[agentID] = settings
    return RemoteAgentSettingsApplyResult(notice: "Host accepted the settings.")
  }

  func applyAgentMode(agentID: String, modeID: String) async throws
    -> RemoteAgentSettingsApplyResult
  {
    modeApplyCalls += 1
    await settingsApplyGate?.wait()
    var settings = try await agentSettings(agentID: agentID)
    guard settings.availableModes.contains(where: { $0.id == modeID }) else {
      throw RemoteServiceError.unavailable("Permission mode unavailable")
    }
    settings.currentModeID = modeID
    settingsByAgentID[agentID] = settings
    return RemoteAgentSettingsApplyResult(notice: "Host accepted the permissions mode.")
  }

  func applyAgentThinking(
    agentID: String, thinkingOptionID: String?, modeID: String?
  ) async throws -> RemoteAgentSettingsApplyResult {
    thinkingApplyCalls += 1
    var settings = try await agentSettings(agentID: agentID)
    settings.thinkingOptionID = normalizedThinkingOptionID ?? thinkingOptionID
    settings.effectiveThinkingOptionID = settings.thinkingOptionID
    if let modeID { settings.currentModeID = modeID }
    settingsByAgentID[agentID] = settings
    return RemoteAgentSettingsApplyResult(notice: "Host accepted the effort.")
  }

  func settingsCallCount() -> Int { settingsCalls }
  func settingsApplyCallCount() -> Int { settingsApplyCalls }
  func thinkingApplyCallCount() -> Int { thinkingApplyCalls }
  func modeApplyCallCount() -> Int { modeApplyCalls }

  func usageCallCount() -> Int { usageCalls }

  func createThread(_ intent: RemoteNewThreadIntent) async throws -> RemoteNewThreadResult {
    submittedCreations.append(intent)
    await creationGate?.wait()
    if failFirstCreation && submittedCreations.count == 1 {
      throw RemoteServiceError.connectionLost("The creation response was lost.")
    }
    if failFirstCreationDefinitively && submittedCreations.count == 1 {
      return RemoteNewThreadResult(
        thread: nil, promptAccepted: false, error: "provider unavailable",
        safeToRestart: true)
    }
    return RemoteNewThreadResult(
      thread: RemoteThread(
        id: "new-thread", title: "New thread", provider: intent.provider,
        model: intent.model, state: .running, requiresAttention: false,
        attentionReason: nil),
      promptAccepted: promptAccepted,
      error: promptAccepted ? nil : "prompt outcome unknown")
  }

  func creationCount() -> Int { submittedCreations.count }
  func creationIntents() -> [RemoteNewThreadIntent] { submittedCreations }

  func connectionEvents() async -> AsyncStream<RemoteConnectionEvent> {
    let (stream, continuation) = AsyncStream<RemoteConnectionEvent>.makeStream()
    connectionContinuation = continuation
    continuation.yield(.connected)
    if let pendingDisconnectReason {
      continuation.yield(.disconnected(pendingDisconnectReason))
      self.pendingDisconnectReason = nil
    }
    return stream
  }

  func projects() async throws -> [RemoteProject] {
    projectCalls += 1
    if projectCalls == projectGateAtCall { await projectGate?.wait() }
    if let projectsError { throw projectsError }
    if projectErrorCalls.contains(projectCalls) {
      throw RemoteServiceError.unavailable("The project catalog was unavailable.")
    }
    if projectCalls > 1, let projectsAfterFirstCall { return projectsAfterFirstCall }
    return projectsValue
  }

  func projectCallCount() -> Int { projectCalls }

  func setProjectsError(_ error: Error?) { projectsError = error }

  func agentForOpenIntent(agentID: String) async throws -> RemoteThread? {
    await openAgentGate?.wait()
    guard
      let project = (projectsAfterFirstCall ?? projectsValue).first(where: {
        "thread-" + $0.id == agentID
      })
    else {
      return nil
    }
    var thread = try await threads(projectID: project.id)[0]
    thread.workspaceID = "workspace-" + project.id
    thread.projectID = project.id
    return thread
  }

  func threads(projectID: String) async throws -> [RemoteThread] {
    if projectID == "A" {
      threadACalls += 1
      if threadACalls == 2 { await threadGateForA?.wait() }
    } else if projectID == "B" {
      threadBCalls += 1
      if threadErrorForB { throw RemoteServiceError.unavailable("B is temporarily unavailable") }
    }
    return [
      RemoteThread(
        id: "thread-\(projectID)", title: "Thread \(projectID)",
        provider: nil, model: nil, state: initialThreadState,
        requiresAttention: false, attentionReason: nil,
        contextUsage: initialThreadContext ?? contextReport,
        cwd: threadCWD)
    ]
  }

  func threadBCallCount() -> Int { threadBCalls }

  func history(agentID: String, before cursor: RemoteTimelineCursor?) async throws -> RemoteTimeline
  {
    await historyGate?.wait()
    if let cursor {
      olderPageCalls += 1
      if endlessOlderPages {
        return RemoteTimeline(
          messages: [], historyMayBeIncomplete: false, hasOlder: true,
          olderCursor: .init(epoch: cursor.epoch, sequence: cursor.sequence + 1), latestCursor: nil)
      }
      return RemoteTimeline(
        messages: olderMessages ?? [], historyMayBeIncomplete: false, hasOlder: false,
        olderCursor: nil, latestCursor: nil)
    }
    return RemoteTimeline(
      messages: historyMessages ?? [
        RemoteMessage(id: "assistant", author: .agent, text: historyText, timestamp: nil)
      ],
      historyMayBeIncomplete: false, hasOlder: olderMessages != nil || endlessOlderPages,
      olderCursor: olderMessages == nil && !endlessOlderPages
        ? nil : .init(epoch: "e1", sequence: 4),
      latestCursor: .init(epoch: "e1", sequence: 5)
    )
  }

  func events(agentID: String) async throws -> AsyncThrowingStream<RemoteTimelineUpdate, Error> {
    let id = UUID()
    let (stream, continuation) = AsyncThrowingStream<RemoteTimelineUpdate, Error>.makeStream()
    timelineContinuations[id] = continuation
    continuation.onTermination = { @Sendable _ in Task { await self.removeTimeline(id) } }
    return stream
  }

  func send(agentID: String, text: String) async throws {
    if sendGateAgentID == nil || sendGateAgentID == agentID { await sendGate?.wait() }
    if failsSending { throw RemoteServiceError.connectionLost("fixture send failed") }
  }

  func send(
    agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior
  ) async throws {
    try await send(
      agentID: agentID, text: text, messageID: messageID,
      behavior: behavior, images: [])
  }

  func send(
    agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior,
    images: [RemoteDraftImage]
  ) async throws {
    sentAgentMessages.append(
      SentAgentMessage(
        agentID: agentID, text: text, messageID: messageID, behavior: behavior,
        images: images))
    let callNumber = sentAgentMessages.count
    if sendGateAgentID == nil || sendGateAgentID == agentID { await sendGate?.wait() }
    if failsSending || failSendCalls.contains(callNumber) {
      throw RemoteServiceError.connectionLost("fixture send failed")
    }
  }

  func sentMessages() -> [SentAgentMessage] { sentAgentMessages }

  func readImage(cwd: String, path: String, maxBytes: Int) async throws -> Data {
    imageReadTargets.append((cwd, path, maxBytes))
    await imageReadGate?.wait()
    return Data([1, 2, 3])
  }

  func recordedImageReads() -> [(cwd: String, path: String, maxBytes: Int)] {
    imageReadTargets
  }

  func stop(agentID: String) async throws -> RemoteAgentControlSnapshot? {
    stopCalls += 1
    await stopGate?.wait()
    if let stopError { throw stopError }
    return stopSnapshot
  }

  func stopCallCount() -> Int { stopCalls }

  func olderPageCallCount() -> Int { olderPageCalls }
  func permissionAnswerCount() -> Int { permissionAnswers }
  func pendingPermissions() async throws -> [RemotePermission] { openPermissions }
  func answerPermission(_ permission: RemotePermission, allow: Bool) async throws {
    permissionAnswers += 1
  }

  func disconnect() async {
    closed = true
    connectionContinuation?.finish()
    connectionContinuation = nil
    for continuation in timelineContinuations.values { continuation.finish() }
    timelineContinuations.removeAll()
  }

  func subscriptionCount() -> Int { timelineContinuations.count }
  func reopen() { closed = false }
  func isClosed() -> Bool { closed }
  func emit(_ update: RemoteTimelineUpdate) {
    for continuation in timelineContinuations.values { continuation.yield(update) }
  }
  func failTimeline(_ error: RemoteServiceError) {
    for continuation in timelineContinuations.values { continuation.finish(throwing: error) }
  }
  func emitDisconnect(_ reason: String) {
    if let connectionContinuation {
      connectionContinuation.yield(.disconnected(reason))
    } else {
      pendingDisconnectReason = reason
    }
  }
  private func removeTimeline(_ id: UUID) { timelineContinuations[id] = nil }
}
