// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import LinkLite

final class UpdatePolicyTests: XCTestCase {
    func testAcceptsThePublishedReleaseURL() {
        let url = URL(string: "https://github.com/matthewrball/linklite/releases/download/v0.3.15/LinkLite-0.3.15.dmg")!
        XCTAssertTrue(UpdatePolicy.acceptsDownload(url, length: 4_314_517))
    }

    func testRejectsRedirectableOrForeignDownloads() {
        let rejected = [
            "https://evil.example/LinkLite-1.dmg",
            "http://github.com/matthewrball/linklite/releases/download/v1/LinkLite-1.dmg",
            "file:///tmp/LinkLite-1.dmg",
            "https://github.com.evil.test/matthewrball/linklite/releases/download/v1/LinkLite-1.dmg",
            "https://user@github.com/matthewrball/linklite/releases/download/v1/LinkLite-1.dmg",
            "https://github.com:8443/matthewrball/linklite/releases/download/v1/LinkLite-1.dmg",
            "https://github.com/other/linklite/releases/download/v1/LinkLite-1.dmg",
            "https://github.com/matthewrball/linklite/releases/download/v1/LinkLite-1.pkg",
            "https://github.com/matthewrball/linklite/releases/download/v1/LinkLite-1.dmg?raw=1",
            "https://github.com/matthewrball/linklite/archive/refs/heads/main.zip"
        ]
        for raw in rejected {
            XCTAssertFalse(
                UpdatePolicy.acceptsDownload(URL(string: raw)!, length: 100),
                raw
            )
        }
        let huge = URL(string: "https://github.com/matthewrball/linklite/releases/download/v1/LinkLite-1.dmg")!
        XCTAssertFalse(UpdatePolicy.acceptsDownload(huge, length: 0))
        XCTAssertFalse(UpdatePolicy.acceptsDownload(huge, length: UpdatePolicy.maxDownloadBytes + 1))
    }

    func testPromptVersionDropsUntrustedText() {
        XCTAssertEqual(UpdatePolicy.promptVersion("0.3.15"), "0.3.15")
        XCTAssertEqual(UpdatePolicy.promptVersion("Install now\nvisit evil.example"), "a new version")
        XCTAssertEqual(UpdatePolicy.promptVersion(String(repeating: "1", count: 40)), "a new version")
    }

    func testFeedURLIsTheBundledGitHubFeed() {
        XCTAssertEqual(
            UpdatePolicy.feedURL,
            "https://raw.githubusercontent.com/matthewrball/linklite/main/appcast.xml"
        )
    }
    @MainActor
    func testSparkleSecurityHooksAreTheSelectorsSparkleCalls() {
        XCTAssertTrue(UpdateSecurityHooks.installed(on: UpdaterDelegate()))
    }
}
