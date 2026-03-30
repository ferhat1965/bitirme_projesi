import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../main.dart'; // PotholeRecord ve Detection sınıflarına erişim için

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('potholes.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
CREATE TABLE records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  detected_at TEXT NOT NULL,
  latitude REAL,
  longitude REAL,
  confidence REAL NOT NULL,
  class_name TEXT NOT NULL,
  image_path TEXT NOT NULL,
  bbox TEXT NOT NULL
)
''');
  }

  Future<PotholeRecord> insertRecord(PotholeRecord record, List<double> bbox) async {
    final db = await instance.database;
    final data = {
      'detected_at': record.timestamp.toIso8601String(),
      'latitude': record.latitude,
      'longitude': record.longitude,
      'confidence': record.confidence,
      'class_name': 'pothole',
      'image_path': record.imagePath,
      'bbox': jsonEncode(bbox),
    };

    final id = await db.insert('records', data);
    return PotholeRecord(
      id: id,
      imagePath: record.imagePath,
      location: record.location,
      timestamp: record.timestamp,
      confidence: record.confidence,
      size: record.size,
      latitude: record.latitude,
      longitude: record.longitude,
    );
  }

  Future<List<PotholeRecord>> fetchRecords() async {
    final db = await instance.database;
    final result = await db.query('records', orderBy: 'detected_at DESC');

    return result.map((json) {
      final bboxStr = json['bbox'] as String;
      final bboxList = List<double>.from(jsonDecode(bboxStr));
      
      return PotholeRecord(
        id: json['id'] as int,
        imagePath: json['image_path'] as String,
        location: 'Kayıtlı Konum', // Gerçek ters konum (reverse geocode) main.dart içinde çözülebilir
        timestamp: DateTime.parse(json['detected_at'] as String).toLocal(),
        confidence: json['confidence'] as double,
        size: _getSizeFromBbox(bboxList),
        latitude: json['latitude'] as double?,
        longitude: json['longitude'] as double?,
      );
    }).toList();
  }

  String _getSizeFromBbox(List<double> bbox) {
    if (bbox.length < 4) return 'Bilinmiyor';
    final area = (bbox[2] - bbox[0]) * (bbox[3] - bbox[1]);
    // Normalize değerlerse (0-1 arası)
    if (area < 0.05) return 'Küçük';
    if (area < 0.15) return 'Orta';
    return 'Büyük';
  }

  Future<int> deleteRecord(int id) async {
    final db = await instance.database;
    return await db.delete('records', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteBulk(List<int> ids) async {
    final db = await instance.database;
    final batch = db.batch();
    for (var id in ids) {
      batch.delete('records', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }
}
