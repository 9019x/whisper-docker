# Whisper in Docker

[OpenAI Whisper](https://github.com/openai/whisper) packaged as a self-contained
container — CPU by default, with optional [NVIDIA and AMD GPU builds](#gpu-acceleration).
No Python, no `pip`, no `ffmpeg` on your host — drop audio in `audio/`, get
transcripts back in the same place.

```bash
docker compose build
cp talk.mp3 audio/
docker compose run --rm whisper talk.mp3 --model base -f srt
# -> audio/talk.srt
```

## Usage

Anything after the service name is passed straight to the `whisper` CLI:

```bash
docker compose run --rm whisper talk.mp3 --model base --language en -f srt
docker compose run --rm whisper --help
```

Pass several files at once. The model loads once and is reused, so batching is far
faster than one container per file:

```bash
docker compose run --rm whisper *.mp4 *.mp3 --model base -f txt
```

Translate to English instead of transcribing in the source language:

```bash
docker compose run --rm whisper interview.m4a --task translate --model small
```

Without Compose:

```bash
docker build -t whisper:cpu .
docker run --rm -v whisper-models:/cache -v "$PWD:/audio:z" \
  whisper:cpu talk.mp3 --model base -f srt
```

Both paths share the same `whisper-models` volume, so models download only once.

## Batch a directory

No Compose needed. From inside the directory, mount it as `/audio` and let your
shell expand the globs — one container, one model load for every file:

```bash
cd ~/recordings
shopt -s nullglob nocaseglob   # drop unmatched patterns; match .MP3 too
docker run --rm -v whisper-models:/cache -v "$PWD:/audio:z" \
  whisper:cpu ./*.mp3 ./*.m4a ./*.mp4 --model base -f srt
```

List extensions rather than a bare `*`, which would feed earlier transcripts back
in. The `./` prefix stops a file named `-foo.mp3` being read as an option.

For anything repeated, `batch.sh` does the same with the bookkeeping handled:

```bash
./batch.sh ~/recordings --model base -f srt        # top level only
./batch.sh -r ~/recordings --model base -f srt     # include subdirectories
./batch.sh --overwrite ~/recordings --model base   # redo everything
```

- Picks up every format in the [input table](#input-formats), case-insensitively.
- **Skips files that already have a transcript** in the requested `-f` format
  (all five for the default `all`), so re-running only processes new arrivals. With
  `--bilingual`, a transcript under any language tag counts.
- Transcripts land next to each source, subdirectories included; `--output_dir`
  is therefore rejected.
- With `-r`, whisper runs once per directory, so the model loads once per directory.
- `--bilingual` adds an English translation beside the source transcript, each file
  named for the language it holds — see [Both languages at once](#both-languages-at-once).
- Set `WHISPER_IMAGE` to use a different tag than `whisper:cpu`.

Both forms assume the directory is writable by uid 1000, the container's user —
true if that's your uid, which `id -u` shows.

## Shell aliases

Add to `~/.bashrc`, adjusting the path to wherever you cloned this repo:

```bash
# Whisper on any file in the current directory, as if installed locally.
alias whisper='docker run --rm -v whisper-models:/cache -v "$PWD:/audio:z" whisper:cpu'

# Batch a directory from anywhere.
alias whisper-batch='~/dev/whisper/batch.sh'

# Subtitles for everything new under the current directory.
alias whisper-srt='~/dev/whisper/batch.sh -r . --model base -f srt'
```

```bash
whisper talk.mp3 --model base -f srt
whisper-batch -r ~/recordings --model small --language en -f txt
whisper-srt --language de        # extra args are appended
```

Keep the single quotes: they defer `$PWD` until the alias runs, so it mounts the
directory you're in rather than the one `.bashrc` was loaded from. The `whisper`
alias shadows a native install of the CLI, if you have one; `\whisper` bypasses it.

**On SELinux hosts, run these from a media directory, not `~`.** The `:z` flag
recursively relabels whatever is mounted, so invoking them from your home
directory would relabel all of it. Docker refuses outright for system paths like
`/tmp` and `/home` (`SELinux relabeling of /tmp is not allowed`).

## Input formats

Whisper decodes through `ffmpeg`, so input support is ffmpeg's — this image ships
Debian's full build (**373 demuxers, 215 audio decoders**), not a stripped one.
Verified working end to end:

| Container | Codec |
| --- | --- |
| `.flac` `.wav` | FLAC, PCM |
| `.mp3` `.m4a` | MP3, AAC |
| `.opus` `.ogg` | Opus, Vorbis |
| `.wma` | WMA v2 |
| `.mp4` `.webm` | H.264 + AAC, VP9 + Opus |

**Video files work directly** — ffmpeg drops the video stream and keeps the audio,
so you can point at an `.mkv` or `.mov` screen recording with no pre-extraction.

## Output formats

`-f {txt,vtt,srt,tsv,json,all}`, written next to the input in `audio/`. The CLI
default is `all`, which emits every format at once; pass `-f` to narrow it.

## Languages

Whisper knows **100 languages**, selectable with `--language` as either an ISO
code or an English name (212 spellings are accepted, including aliases like
`zh` / `Chinese` / `Mandarin`):

```bash
docker compose run --rm whisper talk.mp3 --model base --language ja -f srt
docker compose run --rm whisper talk.mp3 --model base --language Japanese -f srt
```

**Set it explicitly when you know it.** Left unset, Whisper auto-detects using
**only the first 30 seconds** — audio that opens with music, silence or a greeting
in another language gets misidentified, and the entire transcript inherits that
mistake. Naming the language also skips the detection pass.

`--task translate` renders any of the 100 into **English**. That direction only;
Whisper cannot translate into a non-English target.

Invalid values are rejected by the CLI up front, so typos fail loudly rather than
being silently misread. Note the `.en` models are English-only — pair `--language`
with a multilingual model.

### Both languages at once

`--bilingual` transcribes *and* translates in one go, naming each output after the
language it holds:

```bash
docker compose run --rm whisper-bilingual interview.m4a --model small -f srt
# -> audio/interview.ja.srt   what was said
# -> audio/interview.en.srt   the same, in English
```

```bash
./batch.sh --bilingual ~/recordings --model small -f srt
./batch.sh --bilingual --gpu cuda ~/recordings --model turbo -f srt
```

The two files stand side by side; nothing is merged. Each pass segments
independently, so cue *n* of one is not cue *n* of the other — compare them as
transcripts, not line by line.

- **It costs two inference passes.** Whisper decodes `transcribe` and `translate`
  separately, so expect roughly double the time of a plain run. The model is loaded
  once for both.
- **English audio gets one file**, `name.en.srt` — the translation pass is skipped,
  and says so. With `--language` unset this is decided by the same 30-second
  detection described above.
- **Don't pass `--task`**; it's chosen for you, one pass each way. Everything else
  goes through to the CLI untouched, `--help` included.
- `.en` models are rejected — English-only models cannot translate.
- Outputs differ from a plain run, which writes an untagged `name.srt`. An untagged
  file doesn't count as done for `--bilingual`, so switching modes re-transcribes.

The service runs `bilingual.py`, mounted from this repo rather than baked into the
image, so editing it needs no rebuild. **On SELinux hosts the `:ro,z` mount relabels
that one file** to `container_file_t` and leaves it that way — harmless, but it is a
change to a file in your clone.

### Languages outside the 100

Not addable by configuration. Each language is a dedicated token in the tokenizer
with a learned entry in the model's embedding matrix, so a 101st means extending
the vocabulary and training it — fine-tuning, not packaging.

What *is* possible: `--model` accepts a checkpoint path, not just a size name, so
fine-tuned models can be mounted in:

```bash
docker compose run --rm -v /path/to/models:/models:z \
  whisper talk.mp3 --model /models/finetuned.pt --language ja
```

This sharpens a language Whisper already knows — dialects, accents, domain
vocabulary — since the checkpoint still uses the stock tokenizer. It does not add
a new one.

## Models

`--model` accepts any of the below. Append `.en` (e.g. `base.en`) for English-only
variants, which are more accurate at the smaller sizes.

| Size | Parameters | Relative speed | Notes |
| :---: | :---: | :---: | :--- |
| tiny | 39 M | ~10x | ~72 MB download |
| base | 74 M | ~7x | good default |
| small | 244 M | ~4x | |
| medium | 769 M | ~2x | slow on CPU |
| turbo | 809 M | ~8x | optimized `large-v3`, no `.en` |
| large | 1550 M | 1x | impractical on CPU |

Relative speeds are upstream's GPU figures; on CPU everything is far slower, but
the ranking holds. `tiny` and `base` are the realistic choices for CPU-only work —
`turbo` is the best accuracy-per-second if you can spare the RAM.

Models download on first use into the `whisper-models` volume and persist:

```bash
docker volume inspect whisper-models     # where it lives
docker run --rm -v whisper-models:/cache alpine ls -lh /cache/whisper
docker volume rm whisper-models          # reclaim the space
```

## GPU acceleration

Two optional images, built from the same Dockerfile with a different PyTorch:

| Image | GPU | Size | Host needs |
| --- | --- | --- | --- |
| `whisper:cpu` | — | 2.7 GB | nothing |
| `whisper:cuda` | NVIDIA | 6.5 GB | driver 580+, [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) |
| `whisper:rocm` | AMD | 16.7 GB | `amdgpu` driver, a [ROCm-supported GPU](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/reference/system-requirements.html) |

Nothing GPU-specific is installed on the host beyond the driver (plus the
toolkit for NVIDIA): CUDA and ROCm libraries ship inside PyTorch's wheels.

```bash
# NVIDIA
docker compose build whisper-cuda
docker compose run --rm whisper-cuda talk.mp3 --model turbo -f srt

# AMD — pass your render group so the container can open /dev/kfd
export RENDER_GID=$(getent group render | cut -d: -f3)
docker compose build whisper-rocm
docker compose run --rm whisper-rocm talk.mp3 --model turbo -f srt

# Batching picks the image and GPU flags for you
./batch.sh --gpu cuda ~/recordings --model turbo -f srt
./batch.sh --gpu rocm ~/recordings --model turbo -f srt
```

Without Compose:

```bash
docker build --build-arg TORCH_INDEX=cu130 -t whisper:cuda .
docker run --rm --gpus all -v whisper-models:/cache -v "$PWD:/audio:z" \
  whisper:cuda talk.mp3 --model turbo -f srt

docker build --build-arg TORCH_INDEX=rocm7.2 -t whisper:rocm .
docker run --rm --device /dev/kfd --device /dev/dri \
  --group-add video --group-add "$(getent group render | cut -d: -f3)" \
  -v whisper-models:/cache -v "$PWD:/audio:z" \
  whisper:rocm talk.mp3 --model turbo -f srt
```

Whisper uses the GPU automatically when it can see one, and FP16 with it; the
ROCm build presents AMD GPUs through the same `cuda` device. With a GPU,
`turbo` stops being a luxury and becomes the sensible default model.

**It falls back to CPU silently.** If the GPU isn't reachable — missing
toolkit, wrong group, unsupported card — transcription still runs, just slowly.
Check what the container sees:

```bash
docker run --rm --gpus all --entrypoint python whisper:cuda \
  -c 'import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name())'
```

or pass `--device cuda` to whisper, which then fails outright instead of
falling back (with a `torch.load` deserialization error, despite the wording).

**Older hardware.** CUDA 13 needs driver 580+ and drops pre-Turing GPUs
(GTX 10-series and earlier). Build against CUDA 12.6 instead:
`CUDA_INDEX=cu126 docker compose build whisper-cuda`, or
`--build-arg TORCH_INDEX=cu126`. `ROCM_INDEX` does the same for AMD; consumer
Radeons outside AMD's support list often work with
`-e HSA_OVERRIDE_GFX_VERSION=…` (e.g. `10.3.0` for RX 6000).

Available indexes are listed at <https://download.pytorch.org/whl/>.

## Notes

**SELinux hosts** (Fedora, RHEL, openSUSE) need the `:z` suffix on bind mounts or
ffmpeg fails with `Permission denied`. `compose.yaml` already sets it; the flag is
a harmless no-op elsewhere. It's only the raw `docker run` form you must remember it in.

**Keep the `audio/` directory in git.** If the bind-mount source doesn't exist,
Docker creates it as `root` and the container's unprivileged user can't write
transcripts into it.

**File in, file out.** No `/dev/snd` or PulseAudio socket is wired up, so live
microphone capture won't work without extra plumbing.

**Transcripts are owned by you**, not root — the container runs as uid 1000.

## Customizing the build

```bash
docker compose build --build-arg WHISPER_VERSION=20240930
docker compose build --build-arg PYTHON_VERSION=3.12
```

The default image is CPU-only: `torch` comes from PyTorch's CPU wheel index,
which keeps it a fraction of a GPU build's size. `TORCH_INDEX` switches it — see
[GPU acceleration](#gpu-acceleration).

Roughly 700 MB of the image is `triton`, which is unused on CPU but required by
Whisper's dependency metadata on linux/x86_64. It can be removed with a
`pip uninstall -y triton` after install, at the cost of diverging from upstream.

## Roadmap

[ROADMAP.md](ROADMAP.md) collects ideas that aren't built yet, each with the
obstacles that would have to be cleared first — currently
[aligned bilingual output](ROADMAP.md#aligned-bilingual-output), the merged view that
[`--bilingual`](#both-languages-at-once) stops short of.
