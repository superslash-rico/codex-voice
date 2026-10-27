import json
from pathlib import Path
import tempfile
import unittest

from voice_engine import Engine, RolloutAdapter
from reminder_recovery import RecoveryStore


class Speaker:
    def __init__(self):
        self.calls = []
        self.alert_id = None
        self.active = False

    def busy(self):
        return self.active

    def speak(self, key, text):
        self.calls.append((key, text))
        self.alert_id = key
        self.active = True
        return True

    def stop(self, key=None):
        if key is None or key == self.alert_id:
            self.active = False
            self.alert_id = None


class ComputerApprovalTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000
        self.speaker = Speaker()
        self.engine = Engine(self.speaker, now=lambda: self.now)
        self.key = 'desktop-approval:01234567-89ab-4cde-8123-0123456789ab'

    def activate(self):
        return self.engine.event({'action': 'desktop_approval', 'id': self.key,
                                  'active': True, 'title': 'Windows App'})

    def test_visible_card_uses_existing_approval_voice(self):
        self.assertTrue(self.activate())
        alert = self.engine.alerts[self.key]
        self.assertEqual((alert['kind'], alert['source']), ('approval', 'desktop-approval'))
        self.assertIn('Windows App', alert['title'])
        self.now += 4
        self.engine.tick()
        self.assertIn('需要你审批', self.speaker.calls[0][1])

    def test_card_closing_stops_its_reminder(self):
        self.activate()
        self.now += 4
        self.engine.tick()
        self.engine.event({'action': 'desktop_approval', 'id': self.key, 'active': False})
        self.assertNotIn(self.key, self.engine.alerts)
        self.assertFalse(self.speaker.active)

    def test_acknowledgement_is_not_readded_by_a_duplicate_event(self):
        self.activate()
        self.engine.event({'action': 'ack', 'id': self.key})
        self.activate()
        self.assertNotIn(self.key, self.engine.alerts)

    def test_disabled_reminders_stay_disabled(self):
        self.engine.event({'action': 'set_enabled', 'enabled': False})
        self.activate()
        self.assertFalse(self.engine.alerts)

    def test_invalid_native_event_is_ignored(self):
        for patch in [{'id': 'arbitrary'}, {'active': 1}, {'active': 'yes'}]:
            event = {'action': 'desktop_approval', 'id': self.key, 'active': True, 'title': 'Windows App'}
            event.update(patch)
            self.assertFalse(self.engine.event(event))
        self.assertFalse(self.engine.alerts)

    def test_stale_ui_approval_is_not_recovered_after_restart(self):
        self.activate()
        self.engine.add({'id': 'ordinary', 'kind': 'question', 'source': 'manual'})
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'state.json'
            adapter = RolloutAdapter(self.engine, folder)
            store = RecoveryStore(path, now=lambda: self.now)
            store.save(self.engine, adapter, force=True)
            saved = json.loads(path.read_text())
            self.assertEqual([a['id'] for a in saved['alerts']], ['ordinary'])
            # Even an older checkpoint containing a visible-card alert is skipped.
            saved['alerts'].append(self.engine.alerts[self.key])
            path.write_text(json.dumps(saved))
            restored = Engine(Speaker(), now=lambda: self.now)
            store.load(restored, RolloutAdapter(restored, folder))
            self.assertEqual(set(restored.alerts), {'ordinary'})


if __name__ == '__main__':
    unittest.main()
