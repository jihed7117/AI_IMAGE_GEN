#!/usr/bin/env python3
"""Generate a model manifest for AI Image Gen from a Hugging Face ONNX repo.

Output is a JSON file describing the model files (paths, URLs, sizes) that the
app's "Import model from manifest URL" feature consumes.

Examples:
  # Default SD1.5-style ONNX layout from a HF repo.
  python tools/import_model.py nmkd/stable-diffusion-1.5-onnx-fp16 --id my-sd15 --name "My SD 1.5"

  # Explicit file list (anything not on HF, e.g. your own CDN).
  python tools/import_model.py https://cdn.example.com/models/my-sd15 \
      --file text_encoder/model.onnx --file unet/model.onnx --file vae_decoder/model.onnx \
      --family sd15 --resolution 512 --id my-sd15

The generated JSON can then be uploaded to any static host and its URL pasted
into the app under Engine -> Import model from manifest URL.
"""

import argparse
import json
import sys
import urllib.request

HF = "https://huggingface.co"

DEFAULT_FILES = [
    "text_encoder/model.onnx",
    "text_encoder_2/model.onnx",
    "text_encoder_2/config.json",
    "unet/model.onnx",
    "unet/model.onnx_data",
    "unet/weights.pb",
    "vae_decoder/model.onnx",
    "tokenizer/vocab.json",
    "tokenizer/merges.txt",
    "tokenizer_2/vocab.json",
    "tokenizer_2/merges.txt",
]


def hf_file_size(repo: str, path: str) -> int:
    """Resolve the real size of a file in a HF repo (follows LFS redirects)."""
    url = f"{HF}/{repo}/resolve/main/{path}"
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "AI-Image-Gen/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return int(resp.headers.get("Content-Length", 0))
    except Exception as e:
        print(f"  !! {path}: {e}", file=sys.stderr)
        return 0


def http_file_size(url: str) -> int:
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "AI-Image-Gen/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return int(resp.headers.get("Content-Length", 0))
    except Exception as e:
        print(f"  !! {url}: {e}", file=sys.stderr)
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("base", help="HF repo id (org/name) or https base URL prefix")
    ap.add_argument("--id", required=True, help="unique model id (e.g. my-sd15)")
    ap.add_argument("--name", default="", help="display name")
    ap.add_argument("--family", default="sd15", choices=["sd15", "sdxl"], help="architecture family")
    ap.add_argument("--resolution", type=int, default=512)
    ap.add_argument("--dtype", default="fp16", help="fp16 or fp32")
    ap.add_argument("--storage-gb", type=float, default=0, help="approx storage size in GB")
    ap.add_argument("--ram-gb", type=float, default=0, help="approx RAM requirement in GB")
    ap.add_argument("--file", action="append", dest="files", default=[], help="file path (repeatable); default is the standard ONNX layout")
    ap.add_argument("--scheduler", default="linear", choices=["linear", "scaled_linear"], help="beta schedule type")
    ap.add_argument("--out", default="model_manifest.json")
    args = ap.parse_args()

    is_hf = "/" in args.base and not args.base.startswith("http")
    base = HF + f"/{args.base}/resolve/main" if is_hf else args.base.rstrip("/")
    files = args.files or DEFAULT_FILES

    manifest = {
        "id": args.id,
        "name": args.name or args.id,
        "family": args.family,
        "dtype": args.dtype,
        "resolution": args.resolution,
        "storage_gb": args.storage_gb,
        "ram_gb": args.ram_gb,
        "notes": f"Imported from {args.base}",
        "source_url": (HF + f"/{args.base}") if is_hf else args.base,
        "sample_prompt": "a photo of a cat, high quality, detailed",
        "custom": True,
        "scheduler": {
            "beta_start": 0.00085,
            "beta_end": 0.012,
            "num_train_timesteps": 1000,
            "prediction_type": "epsilon",
        },
        "files": [],
    }

    print(f"Resolving {len(files)} files against {base} ...")
    has_missing = False
    for path in files:
        if is_hf:
            size = hf_file_size(args.base, path)
        else:
            url = f"{base}/{path}"
            size = http_file_size(url)
        if size <= 0:
            has_missing = True
        manifest["files"].append({"path": path, "url": f"{base}/{path}", "size": size})
        print(f"  {size:>14,}  {path}")

    total = sum(f["size"] for f in manifest["files"])
    manifest["storage_gb"] = manifest["storage_gb"] or round(total / 1e9, 2)

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
    print(f"\nWrote {args.out} ({len(manifest['files'])} files, ~{total / 1e9:.2f} GB).")
    if has_missing:
        print("WARNING: some files could not be resolved (size 0). Review before importing.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
