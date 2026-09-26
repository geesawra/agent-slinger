import Foundation
import XCTest

@testable import Oesap

final class ToolCallMappingTests: XCTestCase {
  func testShellSnapshotMapsCommandDirectoryExitAndOutput() throws {
    let call = try mapped(
      #"{"type":"tool_call","callId":"call-1","name":"Bash","status":"completed","error":null,"detail":{"type":"shell","command":"printf ready","cwd":"/fixture/work","output":"ready","exitCode":0}}"#,
      turnID: "turn-A")

    XCTAssertEqual(call.rowID, "tool:turn:6:turn-A:call-1")
    XCTAssertEqual(call.callID, "call-1")
    XCTAssertEqual(call.title, "Shell")
    XCTAssertEqual(call.summary, "printf ready")
    XCTAssertEqual(call.status, .completed)
    XCTAssertEqual(call.command, "printf ready")
    XCTAssertEqual(call.cwd, "/fixture/work")
    XCTAssertEqual(call.exitCode, 0)
    XCTAssertEqual(call.sections.map(\.id), ["output"])
    XCTAssertEqual(call.sections.first?.kind, .code)
    XCTAssertEqual(call.sections.first?.content, "ready")
  }

  func testReadEditWriteSearchAndGenericDetailsStayStructured() throws {
    let read = try mapped(
      #"{"callId":"read-1","name":"Read","status":"completed","detail":{"type":"read","filePath":"/fixture/main.swift","content":"line one","offset":12,"limit":3}}"#
    )
    XCTAssertEqual(read.summary, "/fixture/main.swift")
    XCTAssertEqual(read.sections.first?.kind, .filePreview)
    XCTAssertEqual(read.sections.first?.path, "/fixture/main.swift")
    XCTAssertEqual(read.sections.first?.offset, 12)
    XCTAssertEqual(read.sections.first?.limit, 3)

    let edit = try mapped(
      #"{"callId":"edit-1","name":"Edit","status":"completed","detail":{"type":"edit","filePath":"/fixture/main.swift","unifiedDiff":"@@ -1 +1 @@\n-old\n+new"}}"#
    )
    XCTAssertEqual(edit.sections.first?.kind, .diff)
    XCTAssertEqual(edit.sections.first?.path, "/fixture/main.swift")

    let editWithoutDiff = try mapped(
      #"{"callId":"edit-2","name":"Edit","status":"completed","detail":{"type":"edit","filePath":"/fixture/main.swift","oldString":"old","newString":"new"}}"#
    )
    XCTAssertEqual(editWithoutDiff.sections.map(\.id), ["before", "after"])

    let write = try mapped(
      #"{"callId":"write-1","name":"Write","status":"running","detail":{"type":"write","filePath":"/fixture/new.swift","content":"let x = 1"}}"#
    )
    XCTAssertEqual(write.sections.first?.kind, .filePreview)
    XCTAssertEqual(write.sections.first?.content, "let x = 1")

    let search = try mapped(
      #"{"callId":"search-1","name":"grep","status":"completed","detail":{"type":"search","query":"needle","content":"line 3: needle","filePaths":["/fixture/a.swift","/fixture/b.swift"],"webResults":[{"title":"Docs","url":"https://example.invalid/docs"}],"truncated":true}}"#
    )
    XCTAssertEqual(search.title, "Search")
    XCTAssertEqual(search.summary, "needle")
    XCTAssertEqual(search.sections.map(\.id), ["matches", "files", "web-results", "truncated"])
    XCTAssertTrue(search.sections[1].content.contains("/fixture/b.swift"))
    XCTAssertTrue(search.sections.last?.content.contains("truncated") == true)

    let generic = try mapped(
      #"{"callId":"generic-1","name":"vendor_tool","status":"failed","error":{"content":"permission denied"},"detail":{"type":"unknown","input":{"path":"/fixture"},"output":{"ok":false}}}"#
    )
    XCTAssertEqual(generic.title, "Vendor tool")
    XCTAssertEqual(generic.errorText, "permission denied")
    XCTAssertEqual(generic.sections.map(\.id), ["input", "output"])
    XCTAssertTrue(generic.sections[0].content.contains("/fixture"))
    XCTAssertTrue(generic.sections[1].content.contains("false"))

    let worktree = try mapped(
      #"{"callId":"setup-1","name":"paseo_worktree_setup","status":"failed","error":"setup failed","detail":{"type":"worktree_setup","worktreePath":"/fixture/worktree","branchName":"feature","log":"partial log","commands":[{"index":1,"command":"git status","cwd":"/fixture/worktree","log":"status output","status":"completed","exitCode":0}],"truncated":true}}"#
    )
    XCTAssertEqual(worktree.title, "Worktree setup")
    XCTAssertEqual(worktree.summary, "feature")
    XCTAssertEqual(worktree.sections.map(\.id), ["log", "command-1", "truncated"])
    XCTAssertTrue(worktree.sections.last?.content.contains("truncated") == true)
  }

  func testSparseAndFutureDetailsDoNotCrashOrInferFields() throws {
    let sparse = try mapped(
      #"{"callId":"sparse","name":"vendor_run","status":"running"}"#)
    XCTAssertEqual(sparse.title, "Vendor run")
    XCTAssertNil(sparse.command)
    XCTAssertTrue(sparse.sections.isEmpty)

    let future = try mapped(
      #"{"callId":"future","name":"vendor.run","status":"paused","detail":{"type":"future_kind","custom":"value"}}"#
    )
    XCTAssertEqual(future.status, .unknown("paused"))
    XCTAssertEqual(future.name, "vendor.run")
    XCTAssertEqual(future.title, "Vendor run")
    XCTAssertEqual(future.sections.map(\.id), ["details"])
    XCTAssertTrue(future.sections[0].content.contains("custom"))
    let missingIdentity = try object(#"{"name":"missing identity","status":"running"}"#)
    XCTAssertNil(RemoteToolCallMapper.map(missingIdentity))
  }

  func testLifecycleMergeKeepsOmittedDetailAndTerminalStatus() throws {
    let running = try object(
      #"{"callId":"call-1","name":"Bash","status":"running","error":null,"detail":{"type":"shell","command":"printf ready","cwd":"/fixture/work"}}"#
    )
    let completed = try object(
      #"{"callId":"call-1","name":"Bash","status":"completed","error":null,"detail":{"type":"shell","output":"ready","exitCode":0}}"#
    )
    let staleRunning = try object(
      #"{"callId":"call-1","name":"Bash","status":"running","error":null,"detail":{"type":"shell","command":"printf ready"}}"#
    )
    let merged = RemoteToolCallMapper.merge(
      RemoteToolCallMapper.merge(running, with: completed), with: staleRunning)
    let call = try XCTUnwrap(RemoteToolCallMapper.map(merged))
    XCTAssertEqual(call.status, .completed)
    XCTAssertEqual(call.command, "printf ready")
    XCTAssertEqual(call.cwd, "/fixture/work")
    XCTAssertEqual(call.exitCode, 0)
    XCTAssertEqual(call.sections.first?.content, "ready")
  }

  func testUnknownDetailKeepsObjectWhenSparseRevisionUsesPrimitiveOrEmptyArray() throws {
    let prior = try object(
      #"{"callId":"call-2","name":"vendor","status":"running","detail":{"type":"unknown","input":{"path":"/fixture"},"output":{"result":"ready"}}}"#
    )
    let sparse = try object(
      #"{"callId":"call-2","name":"vendor","status":"completed","detail":{"type":"unknown","input":"","output":[]}}"#
    )
    let call = try XCTUnwrap(
      RemoteToolCallMapper.map(RemoteToolCallMapper.merge(prior, with: sparse)))
    XCTAssertEqual(call.status, .completed)
    XCTAssertTrue(call.sections.first?.content.contains("/fixture") == true)
    XCTAssertTrue(call.sections.last?.content.contains("ready") == true)
  }

  private func mapped(_ json: String, turnID: String? = nil) throws -> RemoteToolCall {
    try XCTUnwrap(RemoteToolCallMapper.map(object(json), turnID: turnID))
  }

  private func object(_ json: String) throws -> [String: PaseoJSONValue] {
    let value = try JSONDecoder().decode(PaseoJSONValue.self, from: Data(json.utf8))
    return try XCTUnwrap(value.objectValue)
  }
}
