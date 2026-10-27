import Foundation

@main struct ComputerApprovalTests {
    static func main() {
        let prompt = "允许 ChatGPT 使用 Windows App?"
        precondition(ComputerUseApprovalCard.appName(texts: [prompt], buttons: ["始终允许", "拒绝 Esc", "允许此对话 ↵"]) == "Windows App")
        precondition(ComputerUseApprovalCard.appName(texts: ["Allow ChatGPT to use Calculator?"], buttons: ["Deny", "Allow for this chat"]) == "Calculator")
        precondition(ComputerUseApprovalCard.appName(texts: [prompt], buttons: ["发送"]) == nil)
        precondition(ComputerUseApprovalCard.appName(texts: ["任务运行中"], buttons: ["拒绝", "允许此对话"]) == nil)
        precondition(ComputerUseApprovalCard.appName(texts: [prompt], buttons: ["拒绝"]) == nil)
        var next = 0
        let episodes = ComputerUseApprovalEpisodes(makeID: { next += 1; return String(next) })
        let first = episodes.update(["window:app":"Windows App"], complete: true, now: 0)
        precondition(first.count == 1 && first[0]["active"] as? Bool == true)
        precondition(episodes.update(["window:app":"Windows App"], complete: true, now: 1).isEmpty)
        // One transient unreadable/empty scan must not falsely resolve a prompt.
        precondition(episodes.update([:], complete: false, now: 2).isEmpty)
        precondition(episodes.update([:], complete: true, now: 3).isEmpty)
        let removed = episodes.update([:], complete: true, now: 4)
        precondition(removed.count == 1 && removed[0]["active"] as? Bool == false)
        let second = episodes.update(["window:app":"Windows App"], complete: true, now: 5)
        precondition(second.count == 1 && second[0]["id"] as? String != first[0]["id"] as? String)
        precondition(episodes.update([:], complete: false, now: 22).count == 1)
        precondition(episodes.clear().isEmpty)
        print("Computer Use card controls, quoted-text guard, acknowledgement dedupe, disappearance grace and fresh episodes: PASS")
    }
}
