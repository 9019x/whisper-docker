#!/usr/bin/env python
"""Transcribe in the source language and translate to English, in one run.

Wraps whisper's own CLI, so every whisper flag still works, and names each
output after the language it holds:

    talk.ja.srt   what was said
    talk.en.srt   the same, translated

English audio gets only talk.en.srt -- there is nothing to translate.

Costs two inference passes over the audio: whisper decodes transcribe and
translate separately. The model is loaded once for both.
"""

import argparse
import os
import sys
from importlib import import_module

import whisper
from whisper.tokenizer import TO_LANGUAGE_CODE

# `whisper.transcribe` the attribute is the transcribe *function* -- whisper's
# __init__ shadows the module of the same name. Ask for the module explicitly.
wt = import_module("whisper.transcribe")

# Everything below reaches into whisper's internals, which are not an API.
# Fail here, naming the knob that moves, rather than halfway through a batch.
for owner, attr in ((wt, "cli"), (wt, "get_writer"), (wt, "transcribe"), (whisper, "load_model")):
    if not hasattr(owner, attr):
        sys.exit(
            f"bilingual.py: whisper {whisper.__version__} has no "
            f"{owner.__name__}.{attr}, which this script patches. "
            "Check WHISPER_VERSION in the Dockerfile."
        )

SKIPPED = "__bilingual_skipped__"
langs: dict[str, str] = {}  # audio path -> language code, filled by pass 1
translating = False  # which pass we are in; the writer needs to know


def code(language: str) -> str:
    """Normalize to a two-letter code.

    whisper echoes back whatever it was given: "ja" from --language ja,
    "Japanese" from --language Japanese, a code when it auto-detected. Without
    this, the same audio lands in talk.ja.srt one run and talk.japanese.srt
    the next.
    """
    language = language.lower()
    return TO_LANGUAGE_CODE.get(language, language)


_load_model = whisper.load_model
_models: dict = {}


def load_model(*args, **kwargs):
    """Load once, reuse for the second pass."""
    key = (args, tuple(sorted(kwargs.items())))
    if key not in _models:
        _models[key] = _load_model(*args, **kwargs)
    return _models[key]


_get_writer = wt.get_writer


def get_writer(output_format: str, output_dir: str):
    """Tag each output filename with the language of its contents."""
    inner = _get_writer(output_format, output_dir)

    def write(result, audio_path, *args, **kwargs):
        if result.get(SKIPPED):
            return
        if translating:
            # On a translate pass whisper reports the language it decoded *from*,
            # not the English it produced -- tagging with that would overwrite the
            # source transcript, which is the collision this script exists to fix.
            lang = "en"
        else:
            lang = code(result["language"])
            langs[audio_path] = lang
        # The writer names its output after the input's basename, so putting
        # the language in the path we hand it puts it in the filename:
        # talk.ja.flac -> talk.ja.srt. Nothing reads this path as a file.
        stem, ext = os.path.splitext(audio_path)
        inner(result, f"{stem}.{lang}{ext}", *args, **kwargs)

    return write


_transcribe = wt.transcribe


def translate(model, audio_path, **kwargs):
    """Second pass: skip what was already English, reuse pass 1's detection."""
    lang = langs.get(audio_path)
    if lang == "en":
        print(f"{audio_path}: English, nothing to translate")
        return {SKIPPED: True}
    if lang:
        kwargs["language"] = lang
    return _transcribe(model, audio_path, **kwargs)


def main() -> None:
    global translating

    # Just enough parsing to reject what we cannot honour; --help and every
    # other flag fall through to whisper untouched.
    pre = argparse.ArgumentParser(add_help=False)
    pre.add_argument("--model")
    pre.add_argument("--task")
    known, _ = pre.parse_known_args()

    if known.task:
        sys.exit(
            "bilingual.py: --task is chosen for you here, one pass each way. "
            "Drop it, or use the plain whisper entrypoint for a single task."
        )
    if known.model and known.model.endswith(".en"):
        sys.exit(
            f"bilingual.py: {known.model} is English-only, so it cannot translate. "
            "Use a multilingual model (drop the .en)."
        )

    whisper.load_model = load_model
    wt.get_writer = get_writer

    wt.cli()  # pass 1: transcribe, in whatever language was spoken

    if not langs:
        sys.exit("bilingual.py: nothing was transcribed, so nothing to translate")
    if all(lang == "en" for lang in langs.values()):
        print("bilingual.py: English only, no translation pass needed")
        return

    translating = True
    wt.transcribe = translate
    sys.argv += ["--task", "translate"]  # argparse takes the last --task
    wt.cli()  # pass 2: translate to English


if __name__ == "__main__":
    main()
