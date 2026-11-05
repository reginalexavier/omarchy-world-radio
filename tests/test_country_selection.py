"""Run with python3 -m unittest discover -s tests -v (requires quickshell)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PANEL = Path(__file__).resolve().parents[1] / "Panel.qml"


def block(text, start):
    """Return a brace-delimited body from this panel's JavaScript snippets."""
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[opening + 1:end - 1]


@unittest.skipUnless(shutil.which("quickshell"), "requires quickshell")
class CountrySelectionTest(unittest.TestCase):
    def test_search_selection_survives_result_destruction(self):
        source = PANEL.read_text()
        start = source.index("onClicked:", source.index("model: root.countryMatches"))
        handler = block(source, start)
        helper = ""
        declaration = "function pickSearchedCountry(code, name)"
        if declaration in source:
            helper = declaration + " {" + block(source, source.index(declaration)) + "}"
        qml = '''import QtQuick
import Quickshell
ShellRoot {
    id: root
    property var countryMatches: [{code: "HT", name: "Haiti"}]
    property string selected: ""
    function selectCountry(code, name) {
        selected = code + ":" + name
        countryMatches = []
    }
    HELPER
    Item {
        QtObject {
            id: countryField
            property string text: "Haiti"
            onTextChanged: root.countryMatches = []
        }
        Repeater {
            id: results
            model: root.countryMatches
            delegate: Item {
                required property var modelData
                signal clicked()
                onClicked: { HANDLER }
            }
        }
        Timer {
            interval: 20; running: true
            onTriggered: results.itemAt(0).clicked()
        }
        Timer {
            interval: 150; running: true
            onTriggered: {
                if (root.selected === "HT:Haiti" && countryField.text === ""
                        && results.count === 0) {
                    console.log("PASS: Haiti selected after result destruction")
                    Qt.quit()
                } else {
                    console.log("FAIL: selected=" + root.selected)
                    Qt.exit(1)
                }
            }
        }
    }
}
'''.replace("HELPER", helper).replace("HANDLER", handler)
        with tempfile.TemporaryDirectory(prefix="worldradio-test-") as directory:
            path = Path(directory) / "shell.qml"
            path.write_text(qml)
            result = subprocess.run(
                ["quickshell", "--no-color", "-p", str(path)],
                env={**os.environ, "QT_QPA_PLATFORM": "offscreen"},
                capture_output=True, text=True, timeout=10,
            )
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("PASS: Haiti selected after result destruction", output)
        self.assertNotIn("ReferenceError", output)


if __name__ == "__main__":
    unittest.main()
