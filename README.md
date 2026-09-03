# AI Image Gen

On-device Stable Diffusion image generation for Flutter (Android-first).

Runs a CLIP tokenizer, text encoder, UNet and VAE decoder as ONNX sessions via
FFI, with a DDIM scheduler and classifier-free guidance. Model downloads run in
an Android foreground service with pause/resume/cancel, progress notifications
and persisted state.

## Screens

- **Generate** — prompt, negative prompt, steps, CFG scale, seed, sampler
  (DDIM). Shows a live progress bar with per-step timing.
- **Gallery** — every generated image with its metadata (prompt, settings,
  seed, resolution, date), favorites, and delete.
- **Engine** — download/delete built-in models (SD 1.5, SDXL), monitor
  background downloads, and import custom models from a manifest URL.

## Requirements

- Flutter 3.35+ / Dart 3.9+
- Android 8+ (API 26+). Android 13+ prompts for notification permission.
- Enough storage for the downloaded model (SD 1.5 ~2.1 GB, SDXL ~13.8 GB).

## Setup

```bash
flutter pub get
```

### Java for the Android build

The bundled Gradle 8.12 cannot run on Java 24. Point Gradle at a Java 17/21
JDK via `android/gradle.properties`:

```properties
org.gradle.java.home=C:/Users/<you>/jdk21
```

### ONNX Runtime Android AAR

The `onnxruntime` pub package bundles `libonnxruntime.so` for arm64-v8a and
armeabi-v7a via its own `android/src/main/jniLibs`, so no extra setup is
needed on Android.

### Launcher icon (optional)

```bash
dart run flutter_launcher_icons
```

## Build & run

```bash
flutter run
flutter build apk --debug
```

## Custom models

`tools/import_model.py` generates a model manifest from a Hugging Face ONNX
repo (or any URL prefix). Upload the resulting JSON to a static host and paste
the manifest URL in **Engine → Import model**. See `tools/import_model.py -h`.

## Fast generation with LCM-LoRA (SD 1.5)

`tools/build_lcm_sd15.py` bakes the LCM-LoRA adapter
(`latent-consistency/lcm-lora-sdv1-5`) into the SD 1.5 UNet ONNX weights, so
the app generates in ~4 steps instead of 25:

```bash
pip install onnx numpy safetensors
python tools/build_lcm_sd15.py --out lcm-sd15
```

This downloads the base SD 1.5 ONNX model + the LoRA (~2.1 GB total), merges
it, and writes a complete bundle (`lcm-sd15/`) plus `manifest.json` (marked
`"lcm": true`). Import the bundle with **Engine → Load Model from Device**
(pick the files; `weights.pb` is recognized as external UNet data) or host it
and import the manifest URL. When an LCM model is selected the app
automatically applies its recipe: **4 steps, CFG 1.5, no negative prompt**.
Hardware acceleration (NNAPI on Android / CoreML on iOS) applies to it like
any other model. See `tools/build_lcm_sd15.py -h`.

## Project layout

```
lib/
  main.dart                App entry + navigation
  app_state.dart           Global state (models, params, downloads, gallery)
  model_registry.dart      Built-in model manifests + custom import
  models.dart              ModelSpec / GenerationParams / GalleryItem models
  download_controller.dart Android foreground-service download client
  generation_worker.dart   Isolate worker: tokenizer + ONNX sessions + sampler
  tokenizer.dart           CLIP BPE tokenizer
  database.dart            SQLite-backed gallery metadata
  prefs.dart               Persisted generation settings
  screens/                 generate, gallery, home, settings (engine), splash
android/...                Foreground download service, notification helper,
                           download event receiver
```
