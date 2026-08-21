// Tests/LMStudioKitTests/LMStudioDownloadTests.swift
import Testing
import Foundation
@testable import LMStudioKit

@Test func aModelAlreadyOnDiskFinishesInsteadOfPollingAJobThatDoesNotExist() throws {
    // `status: "already_downloaded"` comes back **without** a `job_id`, so there is nothing to
    // poll. Treating it as a started download would poll nil forever; treating it as a failure
    // would report «уже установлена» as an error.
    let started = try LMStudioDownloadParser.started(Data(#"{"status":"already_downloaded"}"#.utf8))
    #expect(started == .alreadyDownloaded)
}

@Test func aStartedDownloadCarriesTheJobToPollAndItsTotalSize() throws {
    let body = #"{"job_id":"job_493c7c9ded","status":"downloading","total_size_bytes":2279145003,"started_at":"2025-10-03T15:33:23.496Z"}"#
    let started = try LMStudioDownloadParser.started(Data(body.utf8))
    #expect(started == .job(id: "job_493c7c9ded", totalBytes: 2_279_145_003))
}

@Test func aPollCarriesTheByteCountsThatMoveTheBar() throws {
    let body = #"{"job_id":"job_1","status":"downloading","total_size_bytes":100,"downloaded_bytes":25,"bytes_per_second":1048576}"#
    let progress = try LMStudioDownloadParser.progress(Data(body.utf8))
    #expect(progress.fraction == 0.25)
    #expect(progress.isFinished == false)
}

@Test func aPollWithoutByteCountsLeavesTheBarWhereItWas() throws {
    // The property `PullProgress` already has and the reason it is optional: a sample with no
    // counts must not be read as 0%, or the bar snaps back to empty mid-download. Asserted on
    // the sample itself rather than after the stream, because that is where it happens
    // (`docs/reference/TESTING.md`, shape 1).
    let progress = try LMStudioDownloadParser.progress(Data(#"{"job_id":"job_1","status":"paused"}"#.utf8))
    #expect(progress.fraction == nil)
}

@Test func aPausedDownloadReportsItsStateInsteadOfReportingNothing() throws {
    // A user can pause a download in LM Studio's own window. The status has to reach the pane
    // in words — a bar that simply stops moving reads as a hang.
    let progress = try LMStudioDownloadParser.progress(Data(#"{"job_id":"job_1","status":"paused","total_size_bytes":100,"downloaded_bytes":40}"#.utf8))
    #expect(progress.status == "paused")
    #expect(progress.fraction == 0.4)
    #expect(progress.isFinished == false)
}

@Test func aCompletedPollIsTheEndOfTheStream() throws {
    let body = #"{"job_id":"job_1","status":"completed","total_size_bytes":100,"downloaded_bytes":100,"completed_at":"2025-10-03T15:43:12.102Z"}"#
    #expect(try LMStudioDownloadParser.progress(Data(body.utf8)).isFinished)
}

@Test func aFailedDownloadEndsTheStreamWithAnErrorRatherThanAStalledBar() {
    #expect(throws: LMStudioError.self) {
        try LMStudioDownloadParser.progress(Data(#"{"job_id":"job_1","status":"failed","message":"no space"}"#.utf8))
    }
}

@Test func aPollWithoutATotalKeepsTheSizeTheStartResponseAlreadyGave() throws {
    // A paused download answers with no counts, and the bar must not lose the position it had:
    // the start response reported the total, so it is carried into every sample.
    let progress = try LMStudioDownloadParser.progress(
        Data(#"{"job_id":"job_1","status":"paused","downloaded_bytes":525000000}"#.utf8),
        totalBytes: 2_100_000_000)
    #expect(progress.total == 2_100_000_000)
    #expect(progress.fraction == 0.25)
}

@Test func anAlreadyInstalledModelIsATerminalSampleAndNotAnUnfinishedOne() throws {
    // It is the only sample such a «download» produces, so a pane keyed on `isFinished` would
    // otherwise sit on an empty bar for a model that is already on disk.
    let sample = ModelDownloadProgress(status: "already_downloaded", completed: 0, total: 0)
    #expect(sample.isFinished)
    #expect(sample.invitesAnotherPoll == false)
}

@Test func onlyTheTwoStatesThatResumeInviteAnotherPoll() throws {
    // `downloading` and `paused` come back; a cancellation performed in LM Studio's own window,
    // or a status a later version adds, must end the stream rather than being polled once a
    // second for ever.
    for status in ["downloading", "paused"] {
        let progress = try LMStudioDownloadParser.progress(Data(#"{"status":"\#(status)"}"#.utf8))
        #expect(progress.invitesAnotherPoll, "\(status) should keep the stream open")
    }
    for status in ["cancelled", "queued", "something-new"] {
        let progress = try LMStudioDownloadParser.progress(Data(#"{"status":"\#(status)"}"#.utf8))
        #expect(progress.invitesAnotherPoll == false, "\(status) should end the stream")
        #expect(progress.isFinished == false)
    }
}
