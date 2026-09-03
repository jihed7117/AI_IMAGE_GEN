import 'dart:io';

import 'package:aiimagegen/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadState', () {
    test('round-trips through names', () {
      for (final s in DownloadState.values) {
        expect(downloadStateFromName(downloadStateName(s)), s);
      }
    });
  });

  group('ModelSpec', () {
    test('parses a manifest', () {
      final spec = ModelSpec.fromJson({
        'id': 'test',
        'name': 'Test Model',
        'family': 'sd15',
        'resolution': 512,
        'files': [
          {
            'path': 'unet/model.onnx',
            'url': 'https://example.com/unet/model.onnx',
            'size': 100,
          }
        ],
      });
      expect(spec.id, 'test');
      expect(spec.name, 'Test Model');
      expect(spec.resolution, 512);
      expect(spec.latentSize, 64);
      expect(spec.files.length, 1);
      expect(spec.files.first.path, 'unet/model.onnx');
      expect(spec.totalBytes, 100);
      expect(spec.engineConfig['textDim'], 768);
      expect(spec.isSdxl, isFalse);
    });

    test('SDXL defaults to 2048 text dim', () {
      final spec = ModelSpec.fromJson({'id': 'x', 'family': 'sdxl'});
      expect(spec.isSdxl, isTrue);
      expect(spec.engineConfig['textDim'], 2048);
    });

    test('tolerates malformed manifest entries', () {
      final spec = ModelSpec.fromJson({
        'id': 12345, // numeric id must not crash the model list
        'files': [
          'garbage', // non-map entry is skipped
          {
            'path': 'unet/model.onnx', // missing url is tolerated
            'size': '100',
          },
          {
            'path': 'vae_decoder/model.onnx',
            'url': 'https://example.com/vae/model.onnx',
            'size': 50,
          },
        ],
      });
      expect(spec.id, '12345');
      expect(spec.files.length, 2);
      expect(spec.files.first.path, 'unet/model.onnx');
      expect(spec.files.first.url, '');
      expect(spec.files.first.size, 100);
      expect(spec.totalBytes, 150);
    });

    test('filesPresent reports missing files', () async {
      final dir = await Directory.systemTemp.createTemp('aiimagegen_test');
      final spec = ModelSpec.fromJson({
        'id': 'test',
        'files': [
          {
            'path': 'a.onnx',
            'url': 'https://example.com/a.onnx',
            'size': 0,
          }
        ],
      });
      expect(spec.filesPresent(dir.path), isFalse);
      await File('${dir.path}/a.onnx').writeAsString('x');
      expect(spec.filesPresent(dir.path), isTrue);
      await dir.delete(recursive: true);
    });
  });

  group('GenerationParams', () {
    test('defaults and round-trip', () {
      final p = GenerationParams();
      expect(p.steps, 25);
      expect(p.cfgScale, 7.5);
      expect(p.seed, -1);
      final restored = GenerationParams.fromJson(p.toJson());
      expect(restored.steps, p.steps);
      expect(restored.cfgScale, p.cfgScale);
      expect(restored.sampler, 'DDIM');
    });
  });

  group('GalleryItem', () {
    test('maps favorite flag', () {
      final item = GalleryItem(
        id: 3,
        path: '/tmp/x.png',
        prompt: 'a cat',
        favorite: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final restored = GalleryItem.fromMap(item.toMap());
      expect(restored.id, 3);
      expect(restored.favorite, isTrue);
      expect(restored.createdAt.millisecondsSinceEpoch, 1000);
    });
  });
}
