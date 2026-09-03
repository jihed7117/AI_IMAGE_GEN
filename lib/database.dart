import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Local SQLite store for the gallery.
class GalleryDb {
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'aiimagegen.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE gallery (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            prompt TEXT NOT NULL DEFAULT '',
            negative_prompt TEXT NOT NULL DEFAULT '',
            model_id TEXT NOT NULL DEFAULT '',
            seed INTEGER NOT NULL DEFAULT 0,
            steps INTEGER NOT NULL DEFAULT 0,
            cfg REAL NOT NULL DEFAULT 0,
            sampler TEXT NOT NULL DEFAULT '',
            resolution TEXT NOT NULL DEFAULT '',
            favorite INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
      },
    );
    return _db!;
  }

  Future<int> insert(GalleryItem item) async {
    final db = await _database;
    final map = item.toMap()..remove('id');
    return db.insert('gallery', map);
  }

  Future<List<GalleryItem>> list({bool favoritesOnly = false}) async {
    final db = await _database;
    final rows = await db.query(
      'gallery',
      where: favoritesOnly ? 'favorite = 1' : null,
      orderBy: 'created_at DESC',
    );
    return rows.map(GalleryItem.fromMap).toList();
  }

  Future<void> setFavorite(int id, bool favorite) async {
    final db = await _database;
    await db.update(
      'gallery',
      {'favorite': favorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(int id) async {
    final db = await _database;
    await db.delete('gallery', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
