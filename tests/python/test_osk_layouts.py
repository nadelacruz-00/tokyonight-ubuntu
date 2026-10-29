import json
import os
import unittest

import _path
import osk_layouts as ol

FIX = os.path.join(_path.FIXTURES, "osk")


def load(name):
    with open(os.path.join(FIX, name + ".json"), encoding="utf-8") as fh:
        return json.load(fh)


# Landscape rows holding letters: row -> (QWERTY letters, offset of the first
# letter among the row's keys; the first key is TAB / LCTL / LFSH).
ROWS = {2: ("qwertyuiop", 1), 3: ("asdfghjkl", 1), 4: ("zxcvbnm", 1)}


def row_keys(row):
    return [k["key"] for k in _flat(row) if "key" in k]


class OskLayoutsTest(unittest.TestCase):
    def cli(self, keymap, current=""):
        r = _path.run("osk_layouts", "merge", "--keycodes", os.path.join(FIX, keymap + ".json"), "--current", current)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def split_layout(self, res):
        lits = json.loads(ol.parse_gv_string(res["custom_layout"]))
        return json.loads(lits[res["split_index"] - ol.NUM_BUILTIN])

    def test_colemak_cache_places_qwerty_letters_on_the_right_physical_keys(self):
        keycodes = load("us+colemak")
        landscape, portrait = ol.build(keycodes)
        for r, (letters, off) in ROWS.items():
            names = row_keys(landscape[r])[off : off + len(letters)]
            got = "".join(keycodes[n]["layers"]["default"] for n in names)
            self.assertEqual(got, letters, f"landscape row {r}")
        # portrait: rows 2-4 hold qwertyuiop / asdfghjkl; / (shift) zxcvbnm
        self.assertEqual("".join(keycodes[n]["layers"]["default"] for n in row_keys(portrait[2])), "qwertyuiop")
        self.assertEqual("".join(keycodes[n]["layers"]["default"] for n in row_keys(portrait[3])), "asdfghjkl;")
        self.assertEqual("".join(keycodes[n]["layers"]["default"] for n in row_keys(portrait[4])[1:8]), "zxcvbnm")
        # the Colemak 'e' lives on the physical key QWERTY calls K, not AD03
        e_slot = row_keys(landscape[2])[3]
        self.assertEqual(keycodes[e_slot]["layers"]["default"], "e")
        self.assertNotEqual(e_slot, "AD03")

    def test_us_cache_maps_identity(self):
        us = load("us")
        landscape, _ = ol.build(us)
        self.assertEqual(row_keys(landscape[2])[1:6], ["AD01", "AD02", "AD03", "AD04", "AD05"])
        self.assertEqual(row_keys(landscape[2])[3], "AD03")  # the 'e' slot
        for r, (letters, off) in ROWS.items():
            names = row_keys(landscape[r])[off : off + len(letters)]
            self.assertEqual("".join(us[n]["layers"]["default"] for n in names), letters)

    def test_indexes_with_no_existing_layouts(self):
        res = self.cli("us+colemak")
        self.assertEqual(res["split_index"], 10)
        self.assertEqual(res["portrait_index"], 11)
        self.assertEqual(self.split_layout(res)[-1]["name"], "gboard-qwerty-split")

    def test_merge_is_idempotent(self):
        first = self.cli("us+colemak")
        second = self.cli("us+colemak", first["custom_layout"])
        self.assertEqual(second, first)
        names = [ol.layout_name(e) for e in json.loads(ol.parse_gv_string(second["custom_layout"]))]
        self.assertEqual(names, ["gboard-qwerty-split", "gboard-qwerty-portrait"])

    def test_existing_non_gboard_layouts_preserved(self):
        mine = json.dumps([[{"key": "ESC"}], {"name": "mine"}])
        old = json.dumps([[{"key": "ESC"}], {"name": "gboard-qwerty-split"}])
        cur = ol.gv_string(json.dumps([mine, old]))
        res = self.cli("us+colemak", cur)
        lits = json.loads(ol.parse_gv_string(res["custom_layout"]))
        self.assertEqual(lits[0], mine)
        self.assertEqual(len(lits), 3)
        self.assertEqual(res["split_index"], 11)
        self.assertEqual(res["portrait_index"], 12)

    def test_gv_string_roundtrip_and_quoting(self):
        for text in ["[]", 'a"b\\c', "it's", "tab\tnl\n", "é😀", "q'\"x"]:
            self.assertEqual(ol.parse_gv_string(ol.gv_string(text)), text)
        self.assertEqual(ol.gv_string("[]"), "'[]'")
        self.assertEqual(ol.gv_string("it's"), '"it\'s"')

    def test_bad_current_fails_without_output(self):
        r = _path.run("osk_layouts", "merge", "--keycodes", os.path.join(FIX, "us.json"), "--current", "nonsense")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")

    def test_keymap_without_latin_letters_fails(self):
        r = _path.run("osk_layouts", "merge", "--keycodes", os.path.join(_path.FIXTURES, "osk", "empty.json"), "--current", "")
        self.assertEqual(r.returncode, 1)


def _flat(row):
    for k in row:
        if isinstance(k, list):
            yield from k
        elif isinstance(k, dict):
            yield k


if __name__ == "__main__":
    unittest.main()
