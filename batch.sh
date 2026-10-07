#!/usr/bin/env bash
# Transcribe every media file in a directory, transcripts beside each source.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: batch.sh [-r] [--overwrite] [--bilingual] [--gpu cuda|rocm] DIR [whisper args...]

  -r, --recursive   also descend into subdirectories
  --overwrite       redo files that already have a transcript
  --bilingual       also translate to English; outputs carry a language tag,
                    talk.ja.srt beside talk.en.srt (two inference passes)
  --gpu cuda|rocm   use the whisper:cuda or whisper:rocm image and pass the GPU in
  -h, --help        show this help

Everything after DIR goes straight to the whisper CLI, e.g.
  ./batch.sh ~/recordings --model base --language en -f srt
EOF
}

die() { echo "batch.sh: $*" >&2; exit 2; }

gpu=cpu recursive=0 overwrite=0 bilingual=0
while (($#)); do
  case $1 in
    -r|--recursive) recursive=1; shift ;;
    --overwrite)    overwrite=1; shift ;;
    --bilingual)    bilingual=1; shift ;;
    --gpu)          gpu=${2:-}; shift 2 || die "--gpu needs cuda or rocm" ;;
    --gpu=*)        gpu=${1#*=}; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; break ;;
    -*)             die "unknown option '$1' (whisper args go after DIR)" ;;
    *)              break ;;
  esac
done
(($#)) || { usage >&2; exit 2; }

case $gpu in
  cpu)  gpu_args=() ;;
  cuda) gpu_args=(--gpus all) ;;
  rocm) gpu_args=(--device /dev/kfd --device /dev/dri --group-add video)
        # The render group owns /dev/kfd; its GID varies by distro.
        if render=$(getent group render); then gpu_args+=(--group-add "$(cut -d: -f3 <<<"$render")"); fi ;;
  *)    die "--gpu must be cuda or rocm, not '$gpu'" ;;
esac
image=${WHISPER_IMAGE:-whisper:$gpu}
# The bilingual entrypoint lives beside this script and is mounted in, so no
# image rebuild is needed to change it.
self_dir=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
if ((bilingual)) && [[ ! -f $self_dir/bilingual.py ]]; then
  die "--bilingual needs bilingual.py beside batch.sh, not found in $self_dir"
fi
[[ -d $1 ]] || die "not a directory: $1"
dir=$(realpath -- "$1"); shift

# Which transcripts count as "done" depends on -f; whisper's default is all.
fmt=all
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -f|--output_format) fmt=${args[i+1]:-} ;;
    --output_format=*)  fmt=${args[i]#*=} ;;
    -o|--output_dir|--output_dir=*)
      die "--output_dir is not supported; transcripts are written next to each source" ;;
  esac
done
outs=(txt vtt srt tsv json)
[[ $fmt == all ]] || outs=("$fmt")

# --bilingual tags outputs with the language it found (talk.ja.srt), which we
# can't predict, so any tag counts as done.
have_output() {
  local stem=$1 ext=$2 match
  if ((bilingual)); then
    for match in "$dir/$stem".*."$ext"; do [[ -e $match ]] && return 0; done
    return 1
  fi
  [[ -e $dir/$stem.$ext ]]
}

# Containers ffmpeg handles; see the README's input formats table.
exts=(flac wav mp3 m4a opus ogg wma mp4 webm mkv mov)
match=()
for e in "${exts[@]}"; do match+=(-o -iname "*.$e"); done
depth=(-maxdepth 1)
((recursive)) && depth=()

mapfile -d '' found < <(cd "$dir" && find . "${depth[@]}" -type f \( "${match[@]:1}" \) -print0 | sort -z)

todo=() skipped=0
for f in "${found[@]}"; do
  f=${f#./}
  if ((!overwrite)); then
    done=1
    for o in "${outs[@]}"; do
      have_output "${f%.*}" "$o" || { done=0; break; }
    done
    if ((done)); then skipped=$((skipped + 1)); continue; fi
  fi
  todo+=("$f")
done

echo "batch.sh: ${#todo[@]} to transcribe, $skipped already done in $dir" >&2
((${#todo[@]})) || exit 0

# whisper writes into its working directory, so run once per directory with
# -w pointing there. The model loads once per directory.
mapfile -t subdirs < <(for f in "${todo[@]}"; do dirname -- "$f"; done | sort -u)

mounts=(-v whisper-models:/cache -v "$dir:/audio:z") entrypoint=() cmd=()
if ((bilingual)); then
  mounts+=(-v "$self_dir/bilingual.py:/bilingual.py:ro,z")
  entrypoint=(--entrypoint python) cmd=(/bilingual.py)
fi

for sub in "${subdirs[@]}"; do
  batch=()
  for f in "${todo[@]}"; do
    [[ $(dirname -- "$f") == "$sub" ]] && batch+=("./$(basename -- "$f")")
  done
  docker run --rm "${gpu_args[@]}" "${entrypoint[@]}" \
    "${mounts[@]}" \
    -w "/audio/$sub" \
    "$image" "${cmd[@]}" "${batch[@]}" "$@"
done
