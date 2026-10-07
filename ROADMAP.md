# Roadmap

Ideas not yet built, with the known obstacles for each. Nothing here is a commitment.
What the image does today is in the [README](README.md).

## Aligned bilingual output

[`--bilingual`](README.md#both-languages-at-once) ships the source transcript and the
English translation as two files. What it stops short of is putting them *together*:

- a bilingual `.srt` — one cue, both lines, plays in any video player;
- a two-column `.md` or `.html` for reading rather than playback.

Either needs alignment, which is the real work. The two passes segment independently,
so cue *n* of one is not cue *n* of the other: pairing has to go by timestamp overlap,
and overlap is many-to-many in both directions. A translated segment routinely spans
two source segments and vice versa, so a merge has to decide whether to split text it
cannot split (no word timestamps by default), repeat it against each overlapping cue,
or collapse the pair into one longer cue. Picking a rule means looking at real output
in a few languages, not reasoning about it up front.

`--word_timestamps True` would give finer anchors to align on, at the cost of a slower
pass and whisper's own caveat that the feature is experimental.

The merge itself needs no model — it reads two subtitle or JSON files and writes a
third — so it belongs in a small script run with the image's Python, next to
[`bilingual.py`](bilingual.py), not in the inference path.
