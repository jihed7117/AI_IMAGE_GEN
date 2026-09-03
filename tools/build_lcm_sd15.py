#!/usr/bin/env python3
"""Build an LCM-accelerated Stable Diffusion 1.5 ONNX bundle for AI Image Gen.

Merges the LCM-LoRA adapter (latent-consistency/lcm-lora-sdv1-5) into the
Stable Diffusion 1.5 ONNX UNet so the app can generate in ~4 steps instead of
25. The app's ONNX Runtime plugin cannot patch weights at runtime, so the LoRA
must be baked into the UNet weights ahead of time — this script does that.

The output is a complete model bundle (text_encoder, merged unet,
vae_decoder, tokenizer) plus a manifest JSON, matching the exact file layout
the app's built-in SD 1.5 model uses. Import it with either:

  * Engine -> Import model from manifest URL (host the bundle + manifest), or
  * Engine -> Load Model from Device (pick the files from the bundle folder).

After importing, generate with 4 steps and CFG ~1.5 (the app applies these
defaults automatically for models marked "lcm" in their manifest). Hardware
acceleration (NNAPI on Android / CoreML on iOS) is used automatically for any
runnable model.

Requirements: pip install onnx numpy safetensors

Usage:
  # Download the base SD 1.5 ONNX model + LCM-LoRA and build ./lcm-sd15
  python tools/build_lcm_sd15.py --out lcm-sd15

  # Merge into a model already downloaded on this machine
  # (expects the same file layout: unet/model.onnx + unet/weights.pb, ...)
  python tools/build_lcm_sd15.py --base-dir ~/models/sd15-fp16 --out lcm-sd15

  # Emit a manifest with real URLs when hosting the bundle yourself
  python tools/build_lcm_sd15.py --out lcm-sd15 --base-url https://cdn.example.com/lcm-sd15
"""

import argparse
import json
import os
import re
import shutil
import struct
import sys
import urllib.request

import numpy as np
import onnx
from onnx import numpy_helper
from safetensors import safe_open

# Same base the app's built-in "Stable Diffusion 1.5" model downloads.
SD15_BASE = "https://huggingface.co/nmkd/stable-diffusion-1.5-onnx-fp16/resolve/main"
SD15_FILES = [
    ("text_encoder/model.onnx", 246_476_214),
    ("unet/model.onnx", 1_217_704),
    ("unet/weights.pb", 1_718_976_000),
    ("vae_decoder/model.onnx", 99_094_195),
    ("tokenizer/vocab.json", 1_059_962),
    ("tokenizer/merges.txt", 524_619),
]
LCM_LORA_URL = (
    "https://huggingface.co/latent-consistency/lcm-lora-sdv1-5/resolve/main/"
    "pytorch_lora_weights.safetensors"
)
LCM_LORA_SIZE = 134_621_556


def norm(name: str) -> str:
    """Normalize a tensor/module name so dot, slash and underscore separators
    all match (diffusers LoRA keys use '_' where the ONNX export uses '.' or
    '/', e.g. 'attn1_to_q' vs 'attn1.to_q.weight')."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def download(url: str, dest: str, expected_size: int = 0) -> None:
    if os.path.exists(dest) and expected_size > 0 and os.path.getsize(dest) >= expected_size - 64:
        print(f"  already present: {dest}")
        return
    print(f"  downloading {os.path.basename(dest)} ...")
    tmp = dest + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": "AI-Image-Gen/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as fh:
        shutil.copyfileobj(resp, fh, length=1024 * 1024)
    os.replace(tmp, dest)
    if expected_size > 0 and os.path.getsize(dest) < expected_size - 64:
        raise RuntimeError(f"download truncated: {dest}")


def _load_lora(path: str):
    """Reads the LoRA safetensors into {module: (down, up, alpha)} where the
    module name is the diffusers-style path (e.g.
    'down_blocks.0.attentions.0.transformer_blocks.0.attn1.to_k')."""
    lora = {}
    with safe_open(path, framework="np") as f:
        for key in f.keys():
            if key.endswith(".alpha"):
                continue
            # 'lora_unet<module>.lora_down.weight' / '.lora_up.weight'
            m = re.match(r"lora_unet_(.+)\.lora_(down|up)\.weight$", key)
            if not m:
                continue
            module = m.group(1)
            entry = lora.setdefault(module, {})
            entry[m.group(2)] = f.get_tensor(key).astype(np.float32)
            if "alpha" not in entry:
                alpha_key = f"lora_unet_{module}.alpha"
                entry["alpha"] = (
                    float(np.asarray(f.get_tensor(alpha_key))) if alpha_key in f.keys() else 0.0
                )
    return lora


def merge_lora_into_unet(unet_path: str, lora_path: str, out_model: str, out_data: str) -> int:
    """Bakes the LCM-LoRA into an SD 1.5 UNet ONNX model.

    For each LoRA module the delta `alpha/rank * (up @ down)` is added to the
    matching initializer, preserving the original dtype (fp16 for the base
    SD 1.5 bundle). The merged model is written with the same external-data
    layout the app expects (model.onnx + weights.pb).

    Returns the number of LoRA modules applied.
    """
    lora = _load_lora(lora_path)
    print(f"  loaded {len(lora)} LoRA modules from {os.path.basename(lora_path)}")

    model = onnx.load(unet_path)
    inits = {init.name: init for init in model.graph.initializer}

    applied = 0
    missing = 0
    for module, entry in lora.items():
        down = entry["down"]
        up = entry["up"]
        rank = down.shape[0]
        scale = (entry.get("alpha") or rank) / rank
        target = norm(module + ".weight")
        init = next((i for n, i in inits.items() if norm(n) == target), None)
        if init is None:
            missing += 1
            print(f"  !! no ONNX initializer for LoRA module {module}")
            continue
        base = numpy_helper.to_array(init)
        dtype = base.dtype
        base32 = base.astype(np.float32)
        if base32.ndim == 4:
            # 1x1 conv: (out, in, 1, 1)  <-  up[out, r, 1, 1] @ down[r, in, 1, 1]
            delta = (up.reshape(up.shape[0], rank) @ down.reshape(rank, down.shape[1])).reshape(
                base32.shape
            )
        else:
            delta = up @ down
        new = (base32 + scale * delta).astype(dtype)
        init.CopyFrom(numpy_helper.from_array(new, name=init.name))
        applied += 1

    if missing:
        print(f"  WARNING: {missing} LoRA modules had no matching initializer.", file=sys.stderr)

    os.makedirs(os.path.dirname(out_model), exist_ok=True)
    onnx.save(
        model,
        out_model,
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location=os.path.basename(out_data),
        size_threshold=1024,
    )
    print(f"  wrote merged UNet: {out_model} + {os.path.basename(out_data)}")
    return applied


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-dir", default="", help="local dir with the base SD 1.5 ONNX files (skips download)")
    ap.add_argument("--out", default="lcm-sd15", help="output bundle directory")
    ap.add_argument("--id", default="sd15-lcm", help="model id in the manifest")
    ap.add_argument("--name", default="Stable Diffusion 1.5 (LCM)", help="display name")
    ap.add_argument("--base-url", default="", help="https base URL if you will host the bundle (manifest gets real URLs)")
    args = ap.parse_args()

    base_dir = args.base_dir
    if base_dir:
        print(f"Using local base model at {base_dir}")
    else:
        base_dir = os.path.join(args.out, "_base")
        os.makedirs(base_dir, exist_ok=True)
        print("Downloading base SD 1.5 ONNX model ...")
        for rel, size in SD15_FILES:
            dest = os.path.join(base_dir, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            download(f"{SD15_BASE}/{rel}", dest, size)

    lora_path = os.path.join(base_dir, "pytorch_lora_weights.safetensors")
    download(LCM_LORA_URL, lora_path, LCM_LORA_SIZE)

    out = args.out
    os.makedirs(out, exist_ok=True)

    # 1) Merge the LoRA into the UNet.
    src_unet = os.path.join(base_dir, "unet", "model.onnx")
    if not os.path.exists(src_unet):
        print(f"error: {src_unet} not found", file=sys.stderr)
        return 1
    applied = merge_lora_into_unet(
        src_unet,
        lora_path,
        os.path.join(out, "unet", "model.onnx"),
        os.path.join(out, "unet", "weights.pb"),
    )
    if applied == 0:
        print("error: no LoRA modules were applied — aborting.", file=sys.stderr)
        return 1

    # 2) Copy the untouched model files.
    for rel, _ in SD15_FILES:
        if rel.startswith("unet/"):
            continue
        src = os.path.join(base_dir, rel)
        dst = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)

    # 3) Emit the manifest for "Import model from manifest URL".
    files = []
    for rel, _ in SD15_FILES:
        size = os.path.getsize(os.path.join(out, rel))
        url = f"{args.base_url.rstrip('/')}/{rel}" if args.base_url else ""
        files.append({"path": rel, "url": url, "size": size})
    total = sum(f["size"] for f in files)
    manifest = {
        "id": args.id,
        "name": args.name,
        "family": "sd15",
        "dtype": "fp16",
        "resolution": 512,
        "storage_gb": round(total / 1e9, 2),
        "ram_gb": 4,
        "lcm": True,
        "notes": (
            "Stable Diffusion 1.5 with the LCM-LoRA adapter baked into the UNet. "
            "Generates in ~4 steps (use steps 4 and CFG 1.5; keep the negative "
            "prompt empty). The app applies these defaults automatically."
        ),
        "source_url": "https://huggingface.co/latent-consistency/lcm-lora-sdv1-5",
        "sample_prompt": "a photo of a cat, high quality, detailed",
        "custom": True,
        "scheduler": {
            "beta_start": 0.00085,
            "beta_end": 0.012,
            "num_train_timesteps": 1000,
            "prediction_type": "epsilon",
        },
        "files": files,
    }
    manifest_path = os.path.join(out, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)

    print(f"\nDone. Bundle in {out}/ ({total / 1e9:.2f} GB).")
    print(f"Import: Engine -> Load Model from Device (pick the files in {out}/),")
    if args.base_url:
        print(f"or host {out}/ and paste {args.base_url}/manifest.json into "
              "Engine -> Import model from manifest URL.")
    else:
        print(f"or host the bundle and import {manifest_path} via a manifest URL.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
