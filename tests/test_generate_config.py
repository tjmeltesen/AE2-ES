"""Tests for the descriptor-to-ConfigUI configuration generator."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml
from lupa import LuaRuntime


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DESCRIPTOR_PATH = PROJECT_ROOT / "config-descriptor.yml"
GENERATOR_PATH = PROJECT_ROOT / "scripts" / "generate_config.py"


class GenerateConfigTests(unittest.TestCase):
    def test_descriptor_covers_config_ui_persisted_defaults(self):
        descriptor = yaml.safe_load(DESCRIPTOR_PATH.read_text(encoding="utf-8"))
        fields = descriptor["fields"]

        self.assertEqual(
            set(fields),
            {
                "brokerId",
                "modemAddress",
                "telemetryPort",
                "controlPort",
                "useStateMachine",
                "useProgramFramework",
                "useTimeSliceScheduler",
                "useCoroutineTransfer",
                "enableAutoCrafting",
                "enableDiscovery",
                "enablePersistence",
                "enableRemoteControl",
                "machines",
                "machineTypes",
                "redstoneAddress",
                "redstoneSide",
                "meControllerAddr",
                "databaseAddr",
                "machineTransposers",
                "pollInterval",
                "heartbeatInterval",
                "debounceWindow",
                "queueSize",
                "dbSlots",
            },
        )
        self.assertEqual(fields["telemetryPort"]["default"], 123)
        self.assertEqual(fields["controlPort"]["default"], 124)
        for flag in (
            "useStateMachine",
            "useProgramFramework",
            "useTimeSliceScheduler",
            "useCoroutineTransfer",
            "enableAutoCrafting",
            "enableDiscovery",
            "enablePersistence",
            "enableRemoteControl",
        ):
            self.assertIs(fields[flag]["default"], False)

    def test_generated_config_loads_through_config_ui(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_path = Path(temporary_directory) / "ae2es_broker.cfg"
            result = subprocess.run(
                [
                    sys.executable,
                    str(GENERATOR_PATH),
                    "--output",
                    str(output_path),
                ],
                cwd=PROJECT_ROOT,
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(output_path.read_text(encoding="utf-8").startswith("return {"))

            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.execute(
                'package.path = "./src/?.lua;./?.lua;" .. package.path'
            )
            config_ui = lua.eval('require("src.config_ui")')[0]
            filesystem = lua.eval(
                "function(path) "
                f"local file = io.open({json.dumps(str(output_path))}, 'r'); "
                "if file then file:close(); return path == "
                f"{json.dumps(str(output_path))} end; return false end"
            )
            ui = config_ui.new(
                str(output_path), lua.table_from({"filesystem": lua.table_from({"exists": filesystem})})
            )
            config, error = ui.loadConfig(ui)

            self.assertIsNone(error)
            self.assertEqual(config["telemetryPort"], 123)
            self.assertEqual(config["controlPort"], 124)
            self.assertEqual(config["machines"].__len__(), 0)
            self.assertEqual(config["machineTypes"].__len__(), 0)
            self.assertEqual(config["machineTransposers"].__len__(), 0)
            for flag in (
                "useStateMachine",
                "useProgramFramework",
                "useTimeSliceScheduler",
                "useCoroutineTransfer",
                "enableAutoCrafting",
                "enableDiscovery",
                "enablePersistence",
                "enableRemoteControl",
            ):
                self.assertFalse(config[flag], flag)


if __name__ == "__main__":
    unittest.main()
