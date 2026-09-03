# AI Image Gen

<p align="center">
  <strong>Run Stable Diffusion entirely on your device — no cloud, no API keys, no limits.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.35+-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-3.9+-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart">
  <img src="https://img.shields.io/badge/Android-8%2B+%28API+26%29-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/ONNX-Runtime-FF6F00?style=for-the-badge&logo=onnx&logoColor=white" alt="ONNX Runtime">
</p>

---

## Overview

AI Image Gen is a **Flutter application** that runs Stable Diffusion image generation **entirely on-device**. Powered by ONNX Runtime with hardware-accelerated inference, it executes a complete diffusion pipeline — CLIP tokenizer, text encoder, UNet denoiser, and VAE decoder — locally on your Android device with no cloud dependency.

**Supports:**
- **Stable Diffusion 1.5** (fp16, ~2 GB, 512×512)
- **Stable Diffusion XL 1.0** (fp32, ~13.75 GB, 1024×1024)
- **Custom models** via manifest URL or direct device import
- **LCM-LoRA** accelerated models for ~4-step generation

---

## Features

### On-Device Inference
Full diffusion pipeline running locally — CLIP BPE tokenizer, text encoder, UNet denoising loop, and VAE decoder all as ONNX sessions via FFI. Runs in a dedicated Dart Isolate to keep the UI responsive.

### Hardware Acceleration
- **Android:** NNAPI (GPU/NPU/DSP) with automatic CPU fallback
- **iOS:** CoreML (GPU/ANE) with subgraph execution
- **XNNPACK:** Optimized CPU fallback
- Force CPU mode toggle for benchmarking

### Background Downloads
Android foreground service with:
- Live progress notifications with progress bar
- Pause / resume / cancel support
- Persistent state across app restarts
- Per-file retry on transient failures

### Live Device Monitoring
- Real-time CPU usage
- App RAM footprint (PSS)
- Device free/total memory
- Inference provider indicator (GPU vs CPU)
- Low-memory detection

### Gallery System
- SQLite-backed metadata store
- Full image viewer with pinch-to-zoom
- Metadata display (prompt, settings, seed, resolution, model)
- Favorites with filter
- Share via system share sheet
- Auto-save to device gallery

### Generation Parameters
- Configurable steps (5–50)
- CFG scale (1–15)
- Negative prompt
- Seed control (random or fixed)
- Sampler selection (DDIM, Euler)
- All settings persisted across sessions

---

## Screens

| Screen | Description |
|--------|-------------|
| **Generate** | Prompt input, model selector, generation button with live progress panel and per-step timing |
| **Gallery** | Grid of generated images with detail viewer, metadata, favorites, and sharing |
| **Engine** | Model management (download/delete/load), background download monitoring, custom model import |

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Framework** | Flutter 3.35+ |
| **Language** | Dart 3.9+ |
| **ML Runtime** | ONNX Runtime (local fork with fp16 support) |
| **State Management** | Provider (ChangeNotifier) |
| **Database** | SQLite (sqflite) |
| **Inference** | Dart Isolates |
| **Native Code** | Kotlin (Android foreground service, notifications) |
| **Build System** | Gradle 8.12 (Kotlin DSL) |

### Key Dependencies

| Package | Purpose |
|---------|---------|
| `provider` | State management |
| `sqflite` | SQLite gallery metadata |
| `path_provider` | App storage access |
| `shared_preferences` | Persisted settings |
| `image` | PNG encoding |
| `onnxruntime` (local fork) | ONNX inference with fp16 support |
| `file_picker` | Import model files from device |

---

## Requirements

- **Flutter** 3.35+ / **Dart** 3.9+
- **Android 8+** (API 26+). Android 13+ prompts for notification permission.
- **Java 17/21 JDK** for the Android build (Gradle 8.12)
- **Storage:** ~2.1 GB for SD 1.5, ~13.8 GB for SDXL

---

## Getting Started

### 1. Install Dependencies

```bash
flutter pub get
```

### 2. Configure Java for Android Build

The bundled Gradle 8.12 cannot run on Java 24. Point Gradle at a Java 17/21 JDK:

```properties
# android/gradle.properties
org.gradle.java.home=C:/Users/<you>/jdk21
```

### 3. Run the App

```bash
flutter run
```

### 4. Build APK

```bash
flutter build apk --debug
```

### 5. Generate Launcher Icons (Optional)

```bash
dart run flutter_launcher_icons
```

---

## Custom Models

Import any ONNX-compatible Stable Diffusion model:

### Option A: Manifest URL

1. Generate a model manifest from a HuggingFace repo:
   ```bash
   python tools/import_model.py <huggingface_repo_or_url> --id <id> --name <name>
   ```
2. Upload the resulting `manifest.json` to a static host.
3. In the app, go to **Engine → Import Model** and paste the manifest URL.

### Option B: Direct Device Import

1. In the app, go to **Engine → Load Model from Device**.
2. Pick the ONNX files from your device storage.
3. Assign roles (text encoder, UNet, VAE) and set resolution.

See `tools/import_model.py -h` for all options.

---

## LCM-LoRA Acceleration (SD 1.5)

Generate images in **~4 steps** instead of 25 using LCM-LoRA:

```bash
pip install onnx numpy safetensors
python tools/build_lcm_sd15.py --out lcm-sd15
```

This merges the LCM-LoRA adapter into the SD 1.5 UNet weights and outputs a complete bundle with `manifest.json` (marked `"lcm": true`).

**Import the bundle:**
- **Option 1:** Use **Engine → Load Model from Device** and pick the files.
- **Option 2:** Host the bundle and import via manifest URL.

When an LCM model is selected, the app automatically applies:
- **4 steps** (instead of 25)
- **CFG 1.5** (instead of 7.5)
- **No negative prompt**

Hardware acceleration (NNAPI/CoreML) works with LCM models like any other model.

---

## Project Structure

```
aiimagegen/
├── lib/
│   ├── main.dart                    # App entry, navigation, theme
│   ├── app_state.dart               # Global state (Provider)
│   ├── models.dart                  # Data models (ModelSpec, GenerationParams, etc.)
│   ├── model_registry.dart          # Built-in manifests + custom import
│   ├── generation_worker.dart       # Isolate-based diffusion engine
│   ├── tokenizer.dart               # CLIP BPE tokenizer
│   ├── download_controller.dart     # Download manager (MethodChannel)
│   ├── database.dart                # SQLite gallery metadata
│   ├── prefs.dart                   # Persisted user settings
│   └── screens/
│       ├── splash_screen.dart       # Animated splash with branding
│       ├── home_screen.dart         # Main shell with 3-tab navigation
│       ├── generate_screen.dart     # Prompt input + generation UI
│       ├── gallery_screen.dart      # Image grid + detail viewer
│       └── settings_screen.dart     # Model management + settings
│
├── android/
│   └── app/src/main/kotlin/.../
│       ├── MainActivity.kt          # MethodChannel handlers
│       ├── DownloadService.kt       # Foreground download service
│       ├── DownloadEventReceiver.kt # Service-to-Flutter bridge
│       └── NotificationHelper.kt    # Notification utility
│
├── third_party/
│   └── onnxruntime/                 # Local fork with fp16 support
│
├── tools/
│   ├── import_model.py              # Model manifest generator
│   └── build_lcm_sd15.py            # LCM-LoRA merger
│
└── assets/
    ├── icon.png                     # App icon source
    └── logo.png                     # Splash screen logo
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Flutter UI Layer                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │ Generate │  │ Gallery  │  │  Engine  │  │ Splash  │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └─────────┘ │
│       │              │              │                     │
│  ┌────▼──────────────▼──────────────▼─────────────────┐  │
│  │              AppState (Provider)                    │  │
│  └────┬──────────────┬──────────────┬─────────────────┘  │
│       │              │              │                     │
├───────┼──────────────┼──────────────┼─────────────────────┤
│       │         Isolate Layer       │                     │
│  ┌────▼──────────────▼──────────────▼─────────────────┐  │
│  │          GenerationWorker (Dart Isolate)            │  │
│  │  ┌─────────┐ ┌──────────┐ ┌──────┐ ┌────────────┐  │  │
│  │  │Tokenizer│ │CLIP Enc. │ │ UNet │ │VAE Decoder │  │  │
│  │  └─────────┘ └──────────┘ └──────┘ └────────────┘  │  │
│  └────────────────────┬────────────────────────────────┘  │
│                       │                                   │
├───────────────────────┼───────────────────────────────────┤
│                  Native Layer                             │
│  ┌────────────────────▼────────────────────────────────┐  │
│  │              ONNX Runtime (FFI)                      │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │  │
│  │  │  NNAPI   │  │ CoreML   │  │    XNNPACK        │  │  │
│  │  │(Android) │  │  (iOS)   │  │   (CPU Fallback)  │  │  │
│  │  └──────────┘  └──────────┘  └──────────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐  │
│  │          Android Foreground Service                  │  │
│  │  DownloadService + NotificationHelper               │  │
│  └─────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

---

## Android Permissions

| Permission | Purpose |
|------------|---------|
| `INTERNET` | Model file downloads |
| `WRITE_EXTERNAL_STORAGE` | Legacy gallery save (API < 29) |
| `FOREGROUND_SERVICE` | Background model downloads |
| `FOREGROUND_SERVICE_DATA_SYNC` | Download service type |
| `POST_NOTIFICATIONS` | Download progress/complete (API 33+) |
| `WAKE_LOCK` | Keep device awake during generation |

---

## Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

- [Stability AI](https://stability.ai/) for Stable Diffusion models
- [Hugging Face](https://huggingface.co/) for model hosting and ONNX exports
- [ONNX Runtime](https://onnxruntime.ai/) for on-device ML inference
- [Flutter](https://flutter.dev/) for the cross-platform framework
