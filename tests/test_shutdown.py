import unittest
from unittest.mock import MagicMock, patch

from manager.app.ssh_client import Node, NodeSSH


class ShutdownProbeTests(unittest.TestCase):
    def setUp(self):
        self.client = NodeSSH(Node(name="compute-01", host="192.0.2.10"))

    def test_host_remains_online_if_metrics_port_is_reachable(self):
        def connect(address, timeout):
            if address[1] == 22:
                raise OSError("SSH unavailable")
            self.assertEqual(address[1], 9100)
            return MagicMock()

        with patch("manager.app.ssh_client.socket.create_connection", side_effect=connect):
            self.assertTrue(self.client.is_online())

    def test_host_is_unreachable_only_if_both_ports_fail(self):
        with patch("manager.app.ssh_client.socket.create_connection", side_effect=OSError("offline")) as connect:
            self.assertFalse(self.client.is_online())
            self.assertEqual(connect.call_count, 2)

    def test_offline_requires_three_consecutive_negative_probes(self):
        with patch.object(self.client, "is_online", side_effect=[False, False, True, False, False, False]) as probe:
            with patch("manager.app.ssh_client.time.sleep"):
                self.assertTrue(self.client.wait_offline(timeout=60, interval=0))
        self.assertEqual(probe.call_count, 6)

    def test_poweroff_always_requires_acknowledgement(self):
        with patch.object(self.client, "action", return_value="POWER_OFF_REQUESTED=1") as action:
            with patch.object(self.client, "wait_offline", return_value=True) as wait:
                result = self.client.poweroff_and_wait()
        action.assert_called_once_with("poweroff")
        wait.assert_called_once_with(timeout=60)
        self.assertTrue(result["offline"])

    def test_failed_acknowledgement_never_confirms_offline(self):
        with patch.object(self.client, "action", return_value="RENT_NODE_STOPPED=1"):
            with patch.object(self.client, "wait_offline") as wait:
                with self.assertRaises(RuntimeError):
                    self.client.poweroff_and_wait()
        wait.assert_not_called()


if __name__ == "__main__":
    unittest.main()
