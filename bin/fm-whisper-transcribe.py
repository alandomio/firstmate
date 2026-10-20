#!/usr/bin/env python3
"""Transcribe audio from stdin to plain text on stdout, locally, with faster-whisper.

Runs on the transcription host (see docs/telegram.md "Voice notes"), not on the
firstmate machine. Audio never leaves the host: it is read from stdin, written
to a private temp file for decoding (PyAV ships its own ffmpeg libraries, so no
ffmpeg binary is needed), and deleted before exit.

Usage: fm-whisper-transcribe.py [--model small] [--language it] [--threads N] < audio > text
Exit: 0 with the transcript on stdout (empty for silence), 1 on any failure
with one line on stderr.
"""
import argparse
import os
import sys
import tempfile


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("FM_WHISPER_MODEL", "small"))
    ap.add_argument("--language", default="it")
    ap.add_argument("--threads", type=int, default=0)
    ap.add_argument("--timing", action="store_true", help="print timings to stderr")
    args = ap.parse_args()
    data = sys.stdin.buffer.read()
    if not data:
        print("error: no audio on stdin", file=sys.stderr)
        return 1
    try:
        import time
        from faster_whisper import WhisperModel
        t0 = time.time()
        model = WhisperModel(args.model, device="cpu", compute_type="int8", cpu_threads=args.threads)
        t1 = time.time()
        fd, path = tempfile.mkstemp(prefix="fm-whisper-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            segments, info = model.transcribe(path, language=args.language or None, beam_size=1, vad_filter=True)
            text = " ".join(s.text.strip() for s in segments).strip()
        finally:
            os.unlink(path)
        t2 = time.time()
        if args.timing:
            print("load=%.1fs transcribe=%.1fs audio=%.1fs" % (t1 - t0, t2 - t1, info.duration), file=sys.stderr)
    except Exception as e:  # any decode/model failure is one stderr line
        print("error: %s: %s" % (type(e).__name__, str(e)[:200].replace("\n", " ")), file=sys.stderr)
        return 1
    sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
