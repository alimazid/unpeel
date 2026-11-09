import Foundation
import Testing
@testable import UnpeelIOS

@MainActor
struct MenuPromptApprovalTests {
    // Same approval shape as runtimes/claude-code/fixtures/approval-menu.txt.
    private static let approval = """
        Bash command
        git add -A && git status --short
        Auto mode classifier requires confirmation for this command.

        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and don't ask again for: git *
          3. No

        Esc to cancel · Tab to amend
        """

    // Same picker as runtimes/codex/fixtures/update-menu.txt (#55).
    private static let codexUpdate = """

          Update available · 0.166.0 → 0.167.0
          Release notes: https://github.com/openai/codex/releases/latest

        › 1. Update now (runs `npm install -g @openai/codex`)
          2. Skip
          3. Skip until next version

          enter continue · esc skip
        """

    @Test(arguments: ["enter continue · esc skip", "enter\n  continue · esc skip",
                      "enter to confirm or esc to go back", "Press Enter to continue"])
    func pickerWithOnlyAnEnterHint(footer: String) {
        let text = Self.codexUpdate.replacingOccurrences(of: "enter continue · esc skip", with: footer)
        #expect(RemoteGhosttyRenderer.viewportHasMenuPrompt(text))
        let moved = text.replacingOccurrences(of: "› 1.", with: "  1.")
            .replacingOccurrences(of: "  2. Skip\n", with: "› 2. Skip\n")
        #expect(RemoteGhosttyRenderer.viewportHasMenuPrompt(moved))
    }

    @Test
    func enterHintRequiresNearbySelectedChoices() {
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt("Press Enter to continue."))
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt("  enter continue · esc skip"))
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt(
            Self.codexUpdate.replacingOccurrences(of: "›", with: " ")
        ))
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt(
            Self.codexUpdate.replacingOccurrences(of: "  2.", with: "  x.")
                .replacingOccurrences(of: "  3.", with: "  x.")
        ))
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt(
            Self.codexUpdate.replacingOccurrences(of: "  enter continue", with:
                String(repeating: "output\n", count: 13) + "  enter continue")
        ))
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt(
            "› 1. fix the login form\n  2. run the tests\n\n  ? for shortcuts"
        ))
    }

    @Test(arguments: ["Tab to amend", "Tab to\n amend"])
    func approvalWithoutNavigationOrConfirmHint(footer: String) {
        let text = Self.approval.replacingOccurrences(of: "Tab to amend", with: footer)
        #expect(RemoteGhosttyRenderer.viewportHasMenuPrompt(text))
        let moved = text.replacingOccurrences(of: "❯ 1.", with: "  1.")
            .replacingOccurrences(of: "  3.", with: "❯ 3.")
        #expect(RemoteGhosttyRenderer.viewportHasMenuPrompt(moved))
    }

    @Test
    func cancelAmendRequiresNearbySelectedChoices() {
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt("Working… Esc to cancel · Tab to amend"))
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt(
            Self.approval.replacingOccurrences(of: "❯", with: " ")
        ))
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt(
            Self.approval.replacingOccurrences(of: "  2.", with: "  x.")
                .replacingOccurrences(of: "  3.", with: "  x.")
        ))
        #expect(!RemoteGhosttyRenderer.viewportHasMenuPrompt(
            Self.approval.replacingOccurrences(of: "Esc to cancel", with:
                String(repeating: "output\n", count: 13) + "Esc to cancel")
        ))
    }
}
