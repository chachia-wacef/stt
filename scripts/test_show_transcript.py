import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import show_transcript as st  # noqa: E402


def item(text, start=None, kind="pronunciation"):
    entry = {"type": kind, "alternatives": [{"content": text, "confidence": "0.99"}]}
    if start is not None:
        entry["start_time"] = str(start)
        entry["end_time"] = str(start + 0.4)
    return entry


class ShowTranscriptTest(unittest.TestCase):
    def test_plain(self):
        data = {"results": {"transcripts": [{"transcript": "Bonjour tout le monde."}], "items": []}}
        self.assertEqual(st.render(data), "Bonjour tout le monde.")

    def test_speakers(self):
        items = [item("Bonjour", 0.0), item(",", kind="punctuation"), item("ça", 0.5), item("va", 0.9),
                 item("?", kind="punctuation"), item("Très", 2.0), item("bien", 2.4), item(".", kind="punctuation")]
        segments = [
            {"speaker_label": "spk_0", "items": [{"start_time": "0.0", "speaker_label": "spk_0"},
                                                  {"start_time": "0.5", "speaker_label": "spk_0"},
                                                  {"start_time": "0.9", "speaker_label": "spk_0"}]},
            {"speaker_label": "spk_1", "items": [{"start_time": "2.0", "speaker_label": "spk_1"},
                                                  {"start_time": "2.4", "speaker_label": "spk_1"}]},
        ]
        data = {"results": {"transcripts": [{"transcript": "x"}], "items": items,
                            "speaker_labels": {"segments": segments}}}
        self.assertEqual(st.render(data), "[spk_0] Bonjour, ça va?\n[spk_1] Très bien.")

    def test_channels(self):
        ch0 = {"channel_label": "ch_0", "items": [item("Allô", 0.0), item(".", kind="punctuation"),
                                                   item("Oui", 3.0)]}
        ch1 = {"channel_label": "ch_1", "items": [item("Bonjour", 1.0), item("madame", 1.5)]}
        data = {"results": {"transcripts": [{"transcript": "x"}], "items": [],
                            "channel_labels": {"channels": [ch0, ch1]}}}
        self.assertEqual(st.render(data), "[ch_0] Allô.\n[ch_1] Bonjour madame\n[ch_0] Oui")

    def test_empty(self):
        self.assertEqual(st.render({"results": {}}), "")


if __name__ == "__main__":
    unittest.main()
