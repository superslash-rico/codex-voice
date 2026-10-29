import unittest
from voice_engine import Engine


class Speaker:
    def __init__(self):
        self.calls, self.alert_id, self.active = [], None, False
    def busy(self):
        return self.active
    def speak(self, key, text):
        self.calls.append((key, text)); self.alert_id = key; self.active = True
        return True
    def stop(self, key=None):
        if key is None or self.alert_id == key:
            self.active = False; self.alert_id = None


class PresentationTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.speaker = Speaker()
        self.engine = Engine(self.speaker, now=lambda: self.now)
    def mode(self, active=True):
        return self.engine.event({'action':'presentation_mode', 'active':active})
    def add(self, key='result', kind='result'):
        self.engine.add({'id':key, 'thread':key, 'title':'演示期间任务', 'kind':kind})
    def test_all_reminders_remain_pending_without_sound_or_counter_changes(self):
        self.mode()
        for kind in ('result', 'approval', 'question', 'blocked'):
            self.add(kind, kind)
        self.engine.tick()
        self.assertFalse(self.speaker.calls)
        self.assertEqual(len(self.engine.alerts), 4)
        self.assertTrue(all(a['count'] == 0 for a in self.engine.alerts.values()))
        self.assertTrue(self.engine.snapshot()['presentation']['active'])
    def test_entry_stops_current_sound_and_exit_resumes_pending(self):
        self.add(); self.engine.tick()
        self.assertTrue(self.speaker.active)
        self.mode()
        self.assertFalse(self.speaker.active)
        self.assertEqual(self.engine.alerts['result']['count'], 0)
        self.now += 2; self.mode(False); self.engine.tick()
        self.assertEqual(len(self.speaker.calls), 2)
        self.assertEqual(self.engine.alerts['result']['count'], 1)
    def test_heartbeat_renews_runtime_lease_but_does_not_extend_user_mute(self):
        self.engine.muted_until = 5000
        self.mode(); self.now += 7; self.mode(); self.now += 7
        self.assertTrue(self.engine.presentation_active())
        self.now += 2
        self.assertFalse(self.engine.presentation_active())
        self.assertEqual(self.engine.muted_until, 5000)
        self.assertTrue(self.engine.enabled)
    def test_lost_native_owner_expires_and_new_engine_starts_in_normal_mode(self):
        self.add(); self.mode(); self.now += 9; self.engine.tick()
        self.assertEqual(len(self.speaker.calls), 1)
        self.assertFalse(Engine(Speaker(), now=lambda:self.now).presentation_active())
    def test_previews_and_direct_play_obey_presentation_mode(self):
        self.mode()
        self.engine.event({'action':'preview'})
        self.assertIn('演示', self.engine.preview_error)
        self.assertFalse(self.engine.play('preview', 'test', 'test'))
        self.assertFalse(self.speaker.calls)
    def test_exit_preserves_user_disabled_reminders_and_existing_pause(self):
        self.engine.enabled = False; self.engine.muted_until = 5000
        self.mode(); self.mode(False)
        self.assertFalse(self.engine.enabled)
        self.assertEqual(self.engine.muted_until, 5000)
    def test_false_boolean_and_invalid_payloads_cannot_enter_mode(self):
        self.assertFalse(self.engine.event({'action':'presentation_mode', 'active':'true'}))
        self.assertFalse(self.engine.presentation_active())


if __name__ == '__main__':
    unittest.main()
