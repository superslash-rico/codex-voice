import Foundation

@main struct PresenterTests {
    static func main() {
        let presenter = PassportPresenter(), epoch = "0123456789abcdef", session = "1123456789abcdef"
        var context = PresentationContext(connected:true, quietAcknowledged:true, permission:true, frontBundle:"com.microsoft.Powerpoint")
        var changes = 0, keys = [Bool]()
        presenter.changed = { changes += 1 }
        presenter.hello(supported:true, session:session)
        var now = 1000.0
        func request(_ seq: Any, _ op: String, lease: String? = nil, epoch current: String? = nil, session boot: String? = nil) -> Bool {
            let token = lease ?? (presenter.state(context, now:now)["presenterLease"] as! String)
            return presenter.receive(["epoch":current ?? epoch,"session":boot ?? session,"lease":token,"seq":seq,"op":op],
                epoch:epoch,context:context,now:now) { next, _ in keys.append(next); return true }
        }
        assert(!request(1,"next")) // A paired device cannot page until manually enabled.
        assert(request(2,"enable") && presenter.enabled && changes == 1)
        assert(request(3,"next") && keys == [true])
        assert(!request(3,"next"))
        presenter.hello(supported:true,session:session)
        assert(!request(3,"next")) // Repeated HELLO cannot undo deduplication.
        now += 0.2
        assert(request(4,"previous") && keys == [true,false])
        assert(!request(5,"next")) // Button bounce is consumed, not queued.
        now += 0.2
        assert(!request(true,"next"))
        assert(!request(6.5,"next"))
        assert(!request(6,"next",epoch:"deadbeefdeadbeef"))
        assert(!request(6,"next",session:"2123456789abcdef"))
        let oldLease = presenter.state(context,now:now)["presenterLease"] as! String
        now += 3
        assert(!request(6,"next",lease:oldLease)) // Delayed frames expire without execution.
        context.frontBundle = "com.apple.TextEdit"
        assert(presenter.status(context) == 1 && !request(7,"next"))
        context.frontBundle = "com.apple.iWork.Keynote"
        assert(!request(7,"next")) // A blocked frame cannot replay after a focus change.
        assert(request(8,"next"))
        now += 0.2
        presenter.target = .powerpoint
        assert(presenter.status(context) == 1 && !request(9,"next"))
        presenter.target = .automatic
        context.permission = false
        assert(presenter.status(context) == 2 && !request(10,"next"))
        context.permission = true; context.quietAcknowledged = false
        assert(presenter.status(context) == 3 && !request(11,"next"))
        context.quietAcknowledged = true; context.frontBundle = "com.kingsoft.wpsoffice.mac"
        assert(request(12,"previous"))
        context.connected = false
        assert(!request(13,"next"))
        context.connected = true
        assert(request(14,"disable") && !presenter.enabled && changes == 2)
        assert(!request(15,"next"))
        assert(request(16,"enable"))
        presenter.reset()
        assert(!presenter.enabled && !presenter.supported && changes == 4)
        assert(!presenter.setEnabled(true,context:context)) // Old firmware remains usable without presenter support.
        presenter.hello(supported:true,session:"invalid")
        assert(!presenter.supported)
        presenter.hello(supported:true,session:session)
        context.inputIdle = false
        assert(!presenter.setEnabled(true,context:context)) // Do not interrupt a dictation in progress.
        print("Presenter session, expiry, focus, permissions, quiet handshake and one-shot keys: PASS")
    }
}
