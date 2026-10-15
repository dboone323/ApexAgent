import Foundation

// MARK: - ChiefOfStaff: roster-aware commander prompt
//
// The roster is interpolated into a TRUSTED bot's system prompt on every turn,
// and its inputs (name/title/description) are user-editable — and via team
// import, third-party-authored. The caps bound both token spend and how much
// room an imported persona gets to talk to the Chief with system authority.

struct ChiefTeamMember {
    let id: String
    let name: String
    var title: String?
    var descriptionText: String?
    var busy: Bool?
    var hidden: Bool?
    var section: String?
}

enum ChiefOfStaff {
    static let rosterMaxBots = 40
    static let nameMax = 80
    static let roleMax = 120
    static let aboutMax = 200

    static func clip(_ value: String, _ max: Int) -> String {
        value.count > max ? String(value.prefix(max - 1)) + "…" : value
    }

    private static func sectionKey(_ section: String?) -> String {
        section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Dynamic system context for a section's Chief of Staff. It names the
    /// current team on every turn; the live roster tool remains authoritative
    /// for IDs and availability at delegation time.
    static func systemPrompt(
        chiefId: String,
        bots: [ChiefTeamMember],
        canDelegate: Bool
    ) -> String {
        let chief = bots.first { $0.id == chiefId }
        let chiefSection = sectionKey(chief?.section)
        let sectionName = chiefSection.isEmpty ? "General" : chiefSection

        let team = bots.filter { bot in
            bot.id != chiefId
                && !(bot.hidden ?? false)
                && sectionKey(bot.section) == chiefSection
        }

        let listed = team.prefix(rosterMaxBots)
        let overflow = team.count - listed.count

        let roster: String
        if team.isEmpty {
            roster = "- No other visible bots are available yet."
        } else {
            var lines = listed.map { bot -> String in
                let name = clip(bot.name, nameMax)
                let role = clip(bot.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? bot.title!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "General assistant", roleMax)
                let about = bot.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines)
                let availability = (bot.busy ?? false) ? "working right now" : "available"
                let suffix = (about?.isEmpty == false) ? ": \(clip(about!, aboutMax))" : ""
                return "- \(name) — \(role)\(suffix) (\(availability))"
            }
            if overflow > 0 {
                lines.append("- …and \(overflow) more (use the live roster for the full list).")
            }
            roster = lines.joined(separator: "\n")
        }

        let delegation = canDelegate
            ? [
                "Use the live roster to confirm IDs. Use `ask_bot` when a teammate is better suited to part of the request, `delegate_task` for specialized sub-agent execution, `dispatch_swarm` for concurrent multi-bot parallel workloads, or `convene_meeting` for multi-bot discussions.",
                "When the user asks you to assemble a team, create each genuinely useful specialist with a clear role and instructions, then delegate its work. Do not create duplicate or unnecessary bots.",
                "Delegate with a clear, self-contained brief and wait for the teammate's actual reply before claiming its work is complete.",
                "You may consult more than one teammate when the request genuinely benefits, then combine their results into one coherent answer.",
              ].joined(separator: " ")
            : "Your current engine cannot contact teammates. Be honest about that limitation and ask the user to choose a delegation-compatible engine before promising coordinated work."

        return [
            "You are the Chief of Staff for the \(sectionName) section. You are the user's primary contact for this section's team of bots.",
            "Own the outcome: understand the request, decide what to handle yourself, coordinate the right specialists when useful, and return one concise consolidated answer.",
            "Do not delegate trivial work merely to appear busy. Never invent a teammate's progress or result. Normal permission and approval rules still apply.",
            delegation,
            "Current \(sectionName) section team:",
            roster,
        ].joined(separator: "\n")
    }

    /// Convenience overload feeding ApexAgent's own BotProfiles.
    static func systemPrompt(
        chiefId: UUID,
        profiles: [(profile: BotProfile, busy: Bool)],
        canDelegate: Bool,
        section: String? = nil
    ) -> String {
        let members = profiles.map { item in
            ChiefTeamMember(
                id: item.profile.id.uuidString,
                name: item.profile.name,
                title: item.profile.title.isEmpty ? nil : item.profile.title,
                descriptionText: item.profile.descriptionText.isEmpty ? nil : item.profile.descriptionText,
                busy: item.busy,
                hidden: false,
                section: section)
        }
        return systemPrompt(chiefId: chiefId.uuidString, bots: members, canDelegate: canDelegate)
    }

    // MARK: - Markdown Team Roster Directive

    static func formatChiefTeamMarkdown(chiefId: String, bots: [ChiefTeamMember]) -> String {
        guard !bots.isEmpty else {
            return "No team members configured under Chief of Staff directive."
        }

        var md = "### 👑 Chief of Staff Specialist Team Directive (\(bots.count) bots)\n\n"
        md += "| Bot ID | Name | Role Title | Status | Section |\n"
        md += "|---|---|---|---|---|\n"

        for b in bots {
            let isChief = b.id == chiefId
            let role = isChief ? "👑 Chief of Staff" : (b.title ?? "Specialist")
            let status = (b.busy ?? false) ? "⚡️ Busy" : "💤 Available"
            let sec = (b.section?.isEmpty ?? true) ? "General" : b.section!
            let safeName = b.name.replacingOccurrences(of: "|", with: "\\|")
            let safeRole = role.replacingOccurrences(of: "|", with: "\\|")
            md += "| `\(b.id)` | **\(safeName)** | \(safeRole) | \(status) | `\(sec)` |\n"
        }
        return md
    }

}