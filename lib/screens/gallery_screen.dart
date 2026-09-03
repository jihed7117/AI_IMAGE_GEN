import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              const Icon(Icons.photo_library_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${app.gallery.length} images',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              FilterChip(
                label: const Text('Favorites'),
                selected: app.galleryFavoritesOnly,
                onSelected: (_) => app.setGalleryFavoritesOnly(!app.galleryFavoritesOnly),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: app.gallery.isEmpty
              ? const _EmptyGallery()
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1,
                  ),
                  itemCount: app.gallery.length,
                  itemBuilder: (context, i) {
                    final item = app.gallery[i];
                    return _GalleryTile(item: item);
                  },
                ),
        ),
      ],
    );
  }
}

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text('No images yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Generated images will appear here.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _GalleryTile extends StatelessWidget {
  final GalleryItem item;
  const _GalleryTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => GalleryDetail(item: item)),
      ),
      borderRadius: BorderRadius.circular(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(item.path),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const ColoredBox(
                color: Colors.black26,
                child: Center(child: Icon(Icons.broken_image)),
              ),
            ),
            if (item.favorite)
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.favorite, color: Colors.redAccent, size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GalleryDetail extends StatelessWidget {
  final GalleryItem item;
  const GalleryDetail({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(
              item.favorite ? Icons.favorite : Icons.favorite_border,
              color: item.favorite ? Colors.redAccent : Colors.white,
            ),
            onPressed: () => app.toggleFavorite(item),
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share',
            onPressed: () async {
              final ok = await app.shareImage(item.path);
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Share failed — image file is missing.')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await app.deleteGalleryItem(item);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: InteractiveViewer(
                child: Image.file(
                  File(item.path),
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                      color: Colors.white54, size: 64),
                ),
              ),
            ),
          ),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.prompt.isNotEmpty)
                  Text(item.prompt, style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _meta(theme, item.resolution),
                    _meta(theme, '${item.steps} steps'),
                    _meta(theme, 'CFG ${item.cfg.toStringAsFixed(1)}'),
                    _meta(theme, item.sampler),
                    if (item.seed >= 0) _meta(theme, 'seed ${item.seed}'),
                    if (item.modelId.isNotEmpty) _meta(theme, item.modelId),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _meta(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white70, fontSize: 12)),
    );
  }
}
