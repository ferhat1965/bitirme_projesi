import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:bitirme/services/tflite_service.dart';
import 'package:bitirme/services/db_helper.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RoadGuardApp());
}

class RoadGuardApp extends StatelessWidget {
  const RoadGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData.dark().copyWith(
      scaffoldBackgroundColor: const Color(0xFF080C18),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF277BFF),
        secondary: Color(0xFF5B6AA8),
        surface: Color(0xFF101822),
        background: Color(0xFF0C1222),
      ),
    );

    return MaterialApp(
      title: 'RoadGuard AI',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: const MainTabs(),
    );
  }
}

class PotholeRecord {
  PotholeRecord({
    required this.id,
    required this.imagePath,
    required this.location,
    required this.timestamp,
    required this.confidence,
    required this.size,
    this.latitude,
    this.longitude,
  });

  final int id;
  final String imagePath;
  final String location;
  final DateTime timestamp;
  final double confidence;
  final String size;
  final double? latitude;
  final double? longitude;

  String get formattedTime =>
      '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';

  String get formattedDate =>
      '${timestamp.day}.${timestamp.month}.${timestamp.year}';
}

class Detection {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double confidence;
  final String className;
  final int? frame;

  Detection({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.confidence,
    required this.className,
    this.frame,
  });

  Detection copyWith({
    int? frame,
  }) {
    return Detection(
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      confidence: confidence,
      className: className,
      frame: frame ?? this.frame,
    );
  }

  factory Detection.fromJson(Map<String, dynamic> json) {
    List<dynamic>? bbox;
    if (json.containsKey('bbox')) {
      bbox = json['bbox'] as List<dynamic>?;
    }

    return Detection(
      x1:
          json['x1']?.toDouble() ??
          (bbox != null && bbox.length > 0 ? (bbox[0] as num).toDouble() : 0.0),
      y1:
          json['y1']?.toDouble() ??
          (bbox != null && bbox.length > 1 ? (bbox[1] as num).toDouble() : 0.0),
      x2:
          json['x2']?.toDouble() ??
          (bbox != null && bbox.length > 2 ? (bbox[2] as num).toDouble() : 0.0),
      y2:
          json['y2']?.toDouble() ??
          (bbox != null && bbox.length > 3 ? (bbox[3] as num).toDouble() : 0.0),
      confidence: json['confidence']?.toDouble() ?? 0.0,
      className: json['class'] ?? 'pothole',
      frame: json.containsKey('frame') ? (json['frame'] as int?) : null,
    );
  }
}

class VideoDetectionItem {
  final int timeMs;
  final String formattedTime;
  final Detection bestDetection;
  final String thumbnailPath;
  final int totalDetectionsInSecond;

  VideoDetectionItem({
    required this.timeMs,
    required this.formattedTime,
    required this.bestDetection,
    required this.thumbnailPath,
    required this.totalDetectionsInSecond,
  });
}

final sampleRecords = List<PotholeRecord>.generate(6, (index) {
  final conf = (0.74 + Random().nextDouble() * 0.2);
  final sizes = ['Küçük', 'Orta', 'Büyük'];
  return PotholeRecord(
    id: index,
    imagePath: 'assets/placeholder.png',
    location: index % 2 == 0
        ? 'Atatürk Blv. Sağ Şerit'
        : 'Otoban Gişeleri Ayrımı',
    timestamp: DateTime.now().subtract(Duration(minutes: index * 20)),
    confidence: conf,
    size: sizes[index % sizes.length],
    latitude: 41.0082 + (Random().nextDouble() - 0.5) * 0.05,
    longitude: 28.9784 + (Random().nextDouble() - 0.5) * 0.05,
  );
});

class MainTabs extends StatefulWidget {
  const MainTabs({super.key});

  @override
  State<MainTabs> createState() => _MainTabsState();
}

class _MainTabsState extends State<MainTabs> {
  int selectedIndex = 0;
  int cameraMode = 0;
  List<PotholeRecord> records = [];

  @override
  void initState() {
    super.initState();
    _fetchRecords();
  }

  Future<void> _fetchRecords() async {
    try {
      final loaded = await DatabaseHelper.instance.fetchRecords();
      if (mounted) {
        setState(() {
          records = loaded;
        });
      }
    } catch (e) {
      debugPrint('Yerel veritabanı okuma hatası: $e');
    }
  }

  Future<void> _deleteRecord(int id) async {
    try {
      await DatabaseHelper.instance.deleteRecord(id);
      _fetchRecords();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kayıt başarıyla silindi (Yerel)')),
        );
      }
    } catch (e) {
      debugPrint('Kayıt silme hatası: $e');
    }
  }

  Future<void> _deleteBulkRecords(List<int> ids) async {
    try {
      for (final id in ids) {
        await DatabaseHelper.instance.deleteRecord(id);
      }
      _fetchRecords();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Seçili kayıtlar başarıyla silindi (Yerel)'),
          ),
        );
      }
    } catch (e) {
      debugPrint('Toplu kayıt silme hatası: $e');
    }
  }

  String _getSizeFromBbox(List<dynamic> bbox) {
    if (bbox.length < 4) return 'Bilinmiyor';
    final x1 = (bbox[0] as num).toDouble();
    final y1 = (bbox[1] as num).toDouble();
    final x2 = (bbox[2] as num).toDouble();
    final y2 = (bbox[3] as num).toDouble();
    final area = (x2 - x1) * (y2 - y1);
    if (area < 5000) return 'Küçük';
    if (area < 20000) return 'Orta';
    return 'Büyük';
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _CameraTab(
        cameraMode: cameraMode,
        onModeChanged: (value) => setState(() => cameraMode = value),
        onAnalysisComplete: _fetchRecords,
      ),
      _MapTab(records: records),
      _RecordsTab(
        records: records,
        onDelete: _deleteRecord,
        onDeleteBulk: _deleteBulkRecords,
      ),
      const _ProfileTab(),
    ];

    return Scaffold(
      body: pages[selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: (idx) {
          setState(() => selectedIndex = idx);
          if (idx == 2) _fetchRecords();
        },
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFF0C1320),
        selectedItemColor: const Color(0xFF3E8FFF),
        unselectedItemColor: Colors.white70,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.camera_alt),
            label: 'Kamera',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Harita'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Kayıtlar'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profil'),
        ],
      ),
    );
  }
}

class _StatusToken extends StatelessWidget {
  const _StatusToken({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
      ],
    );
  }
}

class _CameraTab extends StatefulWidget {
  const _CameraTab({
    required this.cameraMode,
    required this.onModeChanged,
    required this.onAnalysisComplete,
  });

  final int cameraMode;
  final ValueChanged<int> onModeChanged;
  final Future<void> Function() onAnalysisComplete;

  @override
  State<_CameraTab> createState() => _CameraTabState();
}

class _CameraTabState extends State<_CameraTab> {
  final ImagePicker _picker = ImagePicker();
  bool isSystemRunning = false;
  String? _mediaPath;
  bool _isVideo = false;
  bool _isAnalyzing = false;
  String? _analysisText;
  CameraController? _cameraController;
  VideoPlayerController? _videoController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isLiveDetectionActive = false;
  List<Detection> _currentDetections = [];
  Detection? _latestLiveAlert;
  DateTime? _lastDbSaveTime;

  Position? _latestPosition;
  Position? _lastSavedPosition;
  bool _isDuplicateWait = false;
  Timer? _gpsTimer;

  // Video Analizi yeni listesi
  List<VideoDetectionItem> _videoDetectionsList = [];

  Timer? _detectionTimer;
  double? _mediaWidth;
  double? _mediaHeight;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _requestLocationPermission();
  }

  Future<void> _requestLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    _startGpsTracker();
  }

  void _startGpsTracker() {
    _updateLocation();
    _gpsTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _updateLocation(),
    );
  }

  Future<void> _updateLocation() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always) {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) _latestPosition = last;
        final current = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 4),
        );
        _latestPosition = current;
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant _CameraTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cameraMode != oldWidget.cameraMode) {
      if (_videoController != null &&
          _videoController!.value.isInitialized &&
          _videoController!.value.isPlaying) {
        _videoController!.pause();
      }
      setState(() {
        _mediaPath = null;
        _isVideo = widget.cameraMode == 2;
        _analysisText = null;
        _currentDetections = [];
        _videoDetectionsList = [];
        _mediaWidth = null;
        _mediaHeight = null;
      });
    }
  }

  @override
  void dispose() {
    _isLiveDetectionActive = false;
    _detectionTimer?.cancel();
    _gpsTimer?.cancel();
    _cameraController?.dispose();
    _cameraController = null;
    _videoController?.dispose();
    _videoController = null;
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        _cameraController = CameraController(
          _cameras[0], // Arka kamera
          ResolutionPreset.medium,
        );
        await _cameraController!.initialize();
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('Kamera başlatma hatası: $e');
    }
  }

  void _startLiveDetection() {
    if (_isLiveDetectionActive) return;

    _isLiveDetectionActive = true;
    _cameraController!.startImageStream((CameraImage image) async {
      if (_isAnalyzing || !_isLiveDetectionActive) return;
      _isAnalyzing = true;
      final int startMs = DateTime.now().millisecondsSinceEpoch;

      try {
        final result = await TFLiteService().runFrame(
          yPlane: image.planes[0].bytes,
          width: image.width,
          height: image.height,
          rowStride: image.planes[0].bytesPerRow,
          rotation: _cameraController!.description.sensorOrientation,
          saveImage: true,
          docDirPath: (await getApplicationDocumentsDirectory()).path,
        );

        if (!mounted || !_isLiveDetectionActive) return;
        
        final int elapsedMs = DateTime.now().millisecondsSinceEpoch - startMs;
        final double fps = elapsedMs > 0 ? (1000 / elapsedMs) : 0;

        setState(() {
          _currentDetections = result.detections;
          _analysisText = 'TFLite RealTime | Hız: ${elapsedMs}ms (${fps.toStringAsFixed(1)} FPS)';
        });

        if (result.detections.isNotEmpty) {
          final bestDet = result.detections.reduce(
            (a, b) => a.confidence > b.confidence ? a : b,
          );

          bool shouldSaveToDb = false;
          bool isDuplicate = false;

          if (_lastDbSaveTime == null ||
              DateTime.now().difference(_lastDbSaveTime!) >
                  const Duration(milliseconds: 1500)) {
            shouldSaveToDb = true;

            if (_latestPosition != null && _lastSavedPosition != null) {
              final distance = Geolocator.distanceBetween(
                _lastSavedPosition!.latitude,
                _lastSavedPosition!.longitude,
                _latestPosition!.latitude,
                _latestPosition!.longitude,
              );
              if (distance < 10.0) {
                shouldSaveToDb = false;
                isDuplicate = true;
              }
            }
          }

          setState(() {
            _latestLiveAlert = bestDet;
            _isDuplicateWait = isDuplicate;
          });

          if (shouldSaveToDb && result.savedImagePath != null) {
            _lastDbSaveTime = DateTime.now();
            if (_latestPosition != null) {
              _lastSavedPosition = _latestPosition;
            }

            final pr = PotholeRecord(
              id: 0,
              imagePath: result.savedImagePath!,
              location: "Canlı Tarama GPS",
              timestamp: DateTime.now(),
              confidence: bestDet.confidence,
              size: "Tahmini",
              latitude: _latestPosition?.latitude,
              longitude: _latestPosition?.longitude,
            );
            await DatabaseHelper.instance.insertRecord(pr, [
              bestDet.x1,
              bestDet.y1,
              bestDet.x2,
              bestDet.y2,
            ]);
            
            // Eğer yeni çukur bulunduysa bildirim ışığını biraz tut:
            Future.delayed(const Duration(seconds: 4), () {
              if (mounted) {
                setState(() {
                   _latestLiveAlert = null;
                });
              }
            });
            return; // Çakışmamak için çık.
          }
          
          // Zaten kaydedilen (Duplicate) çukurlar veya GPS'siz uyarı
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              setState(() {
                _latestLiveAlert = null;
                _isDuplicateWait = false;
              });
            }
          });
        }
      } catch (e) {
        debugPrint('Canlı Tarama Hatası: $e');
      } finally {
        if (mounted) {
          setState(() {
            _isAnalyzing = false;
          });
        }
      }
    });
  }

  void _stopLiveDetection() {
    _isLiveDetectionActive = false;
    if (_cameraController != null &&
        _cameraController!.value.isStreamingImages) {
      _cameraController!.stopImageStream();
    }
    setState(() {
      _currentDetections = [];
      _mediaWidth = null;
      _mediaHeight = null;
      _latestLiveAlert = null;
    });
  }

  Future<void> _pickImage() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
    );
    if (picked != null) {
      setState(() {
        _mediaPath = picked.path;
        _isVideo = false;
        _analysisText = null;
        _mediaWidth = null;
        _mediaHeight = null;
        _currentDetections = [];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Resim seçildi ve yüklendi.')),
      );
    }
  }

  Future<void> _pickVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked != null) {
      _videoController?.dispose();
      _videoController = VideoPlayerController.file(File(picked.path));
      await _videoController!.initialize();
      await _videoController!.setLooping(true);
      await _videoController!.pause();

      setState(() {
        _mediaPath = picked.path;
        _isVideo = true;
        _analysisText = null;
        _videoDetectionsList = [];
        _mediaWidth = null;
        _mediaHeight = null;
        _currentDetections = [];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video seçildi ve yüklendi.')),
      );
    }
  }

  Future<void> _analyzeImage() async {
    if (_mediaPath == null || _isVideo) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lütfen önce bir resim seçin.')),
      );
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _analysisText = 'TFLite ile analiz ediliyor...';
      _currentDetections = [];
    });

    try {
      final detections = await TFLiteService().runImage(_mediaPath!);

      double maxConf = 0.0;
      for (var d in detections) {
        if (d.confidence > maxConf) maxConf = d.confidence;
      }

      final bytes = await File(_mediaPath!).readAsBytes();
      final decodedImage = await decodeImageFromList(bytes);

      setState(() {
        _mediaWidth = decodedImage.width.toDouble();
        _mediaHeight = decodedImage.height.toDouble();
        _analysisText =
            'Tespit: ${detections.length} | Güven: ${(maxConf * 100).toStringAsFixed(1)}%';
        _currentDetections = detections;
      });

      if (detections.isNotEmpty) {
        final best = detections.first;
        final pr = PotholeRecord(
          id: 0,
          imagePath: _mediaPath!,
          location: "Yerel Resim (TFLite)",
          timestamp: DateTime.now(),
          confidence: maxConf,
          size: "Tahmini",
          latitude: _latestPosition?.latitude,
          longitude: _latestPosition?.longitude,
        );
        await DatabaseHelper.instance.insertRecord(pr, [
          best.x1,
          best.y1,
          best.x2,
          best.y2,
        ]);
      }

      await widget.onAnalysisComplete();
    } catch (e) {
      setState(() {
        _analysisText = 'TFLite Analiz hatası: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
        });
      }
    }
  }

  void _onModeSelected(int idx) {
    widget.onModeChanged(idx);
    setState(() {
      _mediaPath = null;
      _isVideo = false;
      _mediaWidth = null;
      _mediaHeight = null;
      _analysisText = null;
      _isAnalyzing = false;
      _currentDetections = [];
      if (idx == 0) {
        // Canlı modu - kamera başlat
        _startCameraPreview();
      } else {
        // Resim/Video modu - kamera durdur
        _stopCameraPreview();
      }
    });
  }

  void _startCameraPreview() {
    if (_cameraController != null && !_cameraController!.value.isInitialized) {
      _initializeCamera();
    }
  }

  void _stopCameraPreview() {
    // Kamera preview durduruluyor, ama controller dispose edilmiyor
  }

  Future<void> _analyzeVideo() async {
    if (_mediaPath == null || !_isVideo) return;

    final duration = _videoController?.value.duration;
    if (duration != null && duration.inMinutes > 15) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Hata: Video 15 dakikadan uzun olamaz! İşlem sonlandırıldı.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _analysisText = 'Offline Video AI Başlatıldı... (Lütfen bekleyin)';
      _currentDetections = [];
    });

    try {
      final int totalMs = duration?.inMilliseconds ?? 10000;
      final int step = totalMs ~/ 5; // 4 nokradan örneklem alacağız
      List<Detection> allDetections = [];
      
      final tempDir = await getTemporaryDirectory();

      for (int i = 1; i <= 4; i++) {
        final int targetMs = step * i;
        setState(() {
           _analysisText = 'Yapay Zeka Video Kesiti İlgileniyor: %${(i * 25)}';
        });
        
        final String? path = await vt.VideoThumbnail.thumbnailFile(
          video: _mediaPath!,
          thumbnailPath: tempDir.path,
          imageFormat: vt.ImageFormat.JPEG,
          timeMs: targetMs,
          quality: 100,
        );
        
        if (path != null) {
          final detections = await TFLiteService().runImage(path);
          if (detections.isNotEmpty) {
             for (var d in detections) {
                // Eski Frontend Video Overlay sistemi için kare indexi hesaplaması
                allDetections.add(d.copyWith(frame: (targetMs / 1000.0 * 30).round()));
             }
          }
        }
      }

      setState(() {
        _currentDetections = allDetections;
        if (allDetections.isEmpty) {
           _analysisText = 'TFLite Video Tespit: 0 | Temiz yol.';
        } else {
           _analysisText = 'TFLite Video: ${allDetections.length} Muhtemel Çukur (Oynatın)';
        }
      });
      
    } catch (e) {
      debugPrint("Video Analysis Error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video analizi sırasında bir hata oluştu.')),
      );
    } finally {
      setState(() {
        _isAnalyzing = false;
      });
    }
  }

  void _toggleSystem() {
    setState(() {
      isSystemRunning = !isSystemRunning;
    });

    if (widget.cameraMode == 0) {
      if (isSystemRunning) {
        _startLiveDetection();
      } else {
        _stopLiveDetection();
      }
    }

    final snack = isSystemRunning ? 'Sistem başlatıldı' : 'Sistem durduruldu';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(snack),
        duration: const Duration(milliseconds: 600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const modes = ['Canlı', 'Resim', 'Video'];

    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF111D34),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  _StatusToken(
                    icon: Icons.circle,
                    color: Colors.green,
                    text: 'YOLOv8 AI Aktif',
                  ),
                  _StatusToken(
                    icon: Icons.location_on,
                    color: Colors.white,
                    text: 'Güçlü Sinyal',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Stack(
              children: [
                Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF090F1A),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFF1F355A),
                      width: 1.1,
                    ),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 60, height: 1, color: Colors.white24),
                      const SizedBox(height: 4),
                      Container(width: 1, height: 60, color: Colors.white24),
                    ],
                  ),
                ),
                if (_mediaPath != null)
                  Positioned.fill(
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF3A9BFF),
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final previewSize = Size(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            );

                            return Stack(
                              children: [
                                _isVideo
                                    ? (_videoController != null &&
                                              _videoController!
                                                  .value
                                                  .isInitialized
                                          ? Container(
                                              width: previewSize.width,
                                              height: previewSize.height,
                                              color: Colors.black,
                                              child: FittedBox(
                                                fit: BoxFit.contain,
                                                child: SizedBox(
                                                  width: _videoController!
                                                      .value
                                                      .size
                                                      .width,
                                                  height: _videoController!
                                                      .value
                                                      .size
                                                      .height,
                                                  child: VideoPlayer(
                                                    _videoController!,
                                                  ),
                                                ),
                                              ),
                                            )
                                          : Container(
                                              color: Colors.black87,
                                              child: const Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              ),
                                            ))
                                    : Container(
                                        width: previewSize.width,
                                        height: previewSize.height,
                                        color: Colors.black,
                                        child: FittedBox(
                                          fit: BoxFit.contain,
                                          child: Image.file(
                                            File(_mediaPath!),
                                            fit: BoxFit.contain,
                                          ),
                                        ),
                                      ),
                                if (!_isVideo && _currentDetections.isNotEmpty)
                                  DetectionOverlay(
                                    detections: _currentDetections,
                                    screenSize: previewSize,
                                    mediaSize:
                                        _mediaWidth != null &&
                                            _mediaHeight != null
                                        ? Size(_mediaWidth!, _mediaHeight!)
                                        : null,
                                  ),
                                if (_isVideo &&
                                    _videoController != null &&
                                    _currentDetections.isNotEmpty)
                                  ValueListenableBuilder<VideoPlayerValue>(
                                    valueListenable: _videoController!,
                                    builder: (context, value, child) {
                                      final currentMs =
                                          value.position.inMilliseconds;
                                      final activeDetections =
                                          _currentDetections.where((d) {
                                            if (d.frame == null) return false;
                                            return (currentMs -
                                                        (d.frame! / 30 * 1000)
                                                            .round())
                                                    .abs() <
                                                400;
                                          }).toList();

                                      if (activeDetections.isEmpty)
                                        return const SizedBox.shrink();

                                      return DetectionOverlay(
                                        detections: activeDetections,
                                        screenSize: previewSize,
                                        mediaSize:
                                            _mediaWidth != null &&
                                                _mediaHeight != null
                                            ? Size(_mediaWidth!, _mediaHeight!)
                                            : null,
                                      );
                                    },
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  )
                else if (widget.cameraMode == 0 &&
                    _isCameraInitialized &&
                    _cameraController != null)
                  Positioned.fill(
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF3A9BFF),
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Center(
                          child: AspectRatio(
                            // Telefonlarda CameraController aspect ratio ters çalışır çünkü genelde dikey tutulur (portrait).
                            // Bu yüzden 1 / aspectRatio kullanıyoruz.
                            aspectRatio:
                                1 / _cameraController!.value.aspectRatio,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final previewSize = Size(
                                  constraints.maxWidth,
                                  constraints.maxHeight,
                                );
                                return Stack(
                                  children: [
                                    CameraPreview(_cameraController!),
                                    if (_currentDetections.isNotEmpty)
                                      DetectionOverlay(
                                        detections: _currentDetections,
                                        screenSize: previewSize,
                                        mediaSize:
                                            null, // Asla scale etme, aspect ratio'ya tam fitecek şekilde
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (isSystemRunning)
                  Positioned(
                    top: 20,
                    left: 16,
                    right: 16,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      child: _latestLiveAlert != null
                          ? Container(
                              key: const ValueKey('alertBox'),
                              padding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 16,
                              ),
                              decoration: BoxDecoration(
                                color: _isDuplicateWait
                                    ? Colors.orange.withOpacity(0.90)
                                    : Colors.blueAccent.withOpacity(0.95),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: _isDuplicateWait
                                        ? Colors.orange.withOpacity(0.4)
                                        : Colors.blueAccent.withOpacity(0.4),
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    _isDuplicateWait
                                        ? Icons.info_outline
                                        : Icons.warning_amber_rounded,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _isDuplicateWait
                                              ? 'Aynı Çukur Tespit Edildi'
                                              : 'Çukur Kaydedildi!',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                          ),
                                        ),
                                        Text(
                                          _isDuplicateWait
                                              ? 'G: %${(_latestLiveAlert!.confidence * 100).toStringAsFixed(1)} | Zaten kaydedildi'
                                              : 'G: %${(_latestLiveAlert!.confidence * 100).toStringAsFixed(1)} | Veritabanına aktarıldı',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Container(
                              key: const ValueKey('scanningBox'),
                              padding: const EdgeInsets.symmetric(
                                vertical: 6,
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withOpacity(0.8),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'CANLI TARAMA AKTİF',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0D172F),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1C2B49)),
            ),
            child: Row(
              children: List.generate(modes.length, (idx) {
                final active = idx == widget.cameraMode;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => _onModeSelected(idx),
                    child: Container(
                      height: 40,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFF3E8BFF)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          modes[idx],
                          style: TextStyle(
                            color: active ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: ElevatedButton.icon(
              onPressed: (_isAnalyzing && widget.cameraMode != 0)
                  ? null
                  : () {
                      switch (widget.cameraMode) {
                        case 0:
                          _toggleSystem();
                          break;
                        case 1:
                          if (_mediaPath == null) {
                            _pickImage();
                          } else {
                            _analyzeImage();
                          }
                          break;
                        case 2:
                          if (_mediaPath == null) {
                            _pickVideo();
                          } else {
                            _analyzeVideo();
                          }
                          break;
                      }
                    },
              icon: Icon(
                widget.cameraMode == 0
                    ? (isSystemRunning
                          ? Icons.stop_circle
                          : Icons.play_circle_fill)
                    : (widget.cameraMode == 2
                          ? Icons.videocam
                          : Icons.upload_file),
                color: Colors.white,
              ),
              label: Text(
                widget.cameraMode == 0
                    ? (isSystemRunning ? 'Sistemi Durdur' : 'Sistemi Başlat')
                    : widget.cameraMode == 1
                    ? (_mediaPath == null ? 'Resim Yükle' : 'Analiz Et')
                    : (_mediaPath == null ? 'Video Yükle' : 'Analiz Et'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: const Color(0xFF307BFF),
              ),
            ),
          ),
          if (_analysisText != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Text(
                _analysisText!,
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (_mediaPath != null &&
              _isVideo &&
              _videoController?.value.isInitialized == true)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    iconSize: 32,
                    color: Colors.white,
                    icon: Icon(
                      _videoController!.value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                    ),
                    onPressed: () {
                      if (_videoController!.value.isPlaying) {
                        _videoController!.pause();
                      } else {
                        _videoController!.play();
                      }
                      setState(() {});
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: _videoController!,
                      builder: (context, value, child) {
                        return VideoProgressIndicator(
                          _videoController!,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          colors: const VideoProgressColors(
                            playedColor: Colors.blueAccent,
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.black45,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          if (_videoDetectionsList.isNotEmpty)
            Container(
              height: 140,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: _videoDetectionsList.length,
                itemBuilder: (context, index) {
                  final item = _videoDetectionsList[index];
                  return GestureDetector(
                    onTap: () {
                      if (_videoController != null &&
                          _videoController!.value.isInitialized) {
                        _videoController!.seekTo(
                          Duration(milliseconds: item.timeMs),
                        );
                        if (!_videoController!.value.isPlaying) {
                          _videoController!.play();
                          setState(() {});
                        }
                      }
                    },
                    child: Container(
                      width: 110,
                      margin: EdgeInsets.only(
                        left: 14,
                        right: index == _videoDetectionsList.length - 1
                            ? 14
                            : 0.0,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF162445),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF284882)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(11),
                              ),
                              child: Image.file(
                                File(item.thumbnailPath),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      item.formattedTime,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Icon(
                                      Icons.play_circle,
                                      color: Colors.white70,
                                      size: 14,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'G: %${(item.bestDetection.confidence * 100).toStringAsFixed(1)}',
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _MapTab extends StatefulWidget {
  final List<PotholeRecord> records;
  const _MapTab({Key? key, required this.records}) : super(key: key);

  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> {
  final MapController _mapController = MapController();
  List<Marker> _markers = [];

  @override
  void initState() {
    super.initState();
    _buildMarkers();
  }

  @override
  void didUpdateWidget(covariant _MapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.records != oldWidget.records) {
      _buildMarkers();
    }
  }

  void _buildMarkers() {
    final markers = <Marker>[];
    for (var record in widget.records) {
      if (record.latitude != null && record.longitude != null) {
        markers.add(
          Marker(
            width: 48.0,
            height: 48.0,
            point: LatLng(record.latitude!, record.longitude!),
            builder: (ctx) => GestureDetector(
              onTap: () => _showPotholeDetails(record),
              child: const Icon(
                Icons.warning_rounded,
                color: Colors.redAccent,
                size: 38,
              ),
            ),
          ),
        );
      }
    }
    setState(() {
      _markers = markers;
    });

    if (markers.isNotEmpty) {
      _centerMarkers();
    }
  }

  void _centerMarkers() {
    if (_markers.isEmpty) return;
    double sumLat = 0;
    double sumLng = 0;
    for (var m in _markers) {
      sumLat += m.point.latitude;
      sumLng += m.point.longitude;
    }
    final center = LatLng(sumLat / _markers.length, sumLng / _markers.length);

    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        try {
          _mapController.move(center, 12.0);
        } catch (_) {}
      }
    });
  }

  void _showPotholeDetails(PotholeRecord record) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0C1320),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: const Color(0xFF1F355A)),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: record.imagePath.startsWith('http')
                        ? Image.network(
                            record.imagePath,
                            width: 100,
                            height: 100,
                            fit: BoxFit.cover,
                          )
                        : Image.asset(
                            record.imagePath,
                            width: 100,
                            height: 100,
                            fit: BoxFit.cover,
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tespit #${record.id}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on,
                              size: 14,
                              color: Colors.white54,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                record.location,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.access_time,
                              size: 14,
                              color: Colors.white54,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${record.formattedDate} - ${record.formattedTime}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: Colors.redAccent.withOpacity(0.5),
                            ),
                          ),
                          child: Text(
                            'Güven: %${(record.confidence * 100).toStringAsFixed(1)} | Boyut: ${record.size}',
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF111D34),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _StatusToken(
                    icon: Icons.circle,
                    color: Colors.green,
                    text: '${_markers.length} Çukur',
                  ),
                  const _StatusToken(
                    icon: Icons.map,
                    color: Colors.blueAccent,
                    text: 'Karanlık Harita',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF090F1A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1F355A), width: 1.1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    center: LatLng(41.0082, 28.9784),
                    zoom: 11.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                      subdomains: const ['a', 'b', 'c', 'd'],
                      userAgentPackageName: 'com.example.bitirme',
                    ),
                    MarkerLayer(markers: _markers),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordsTab extends StatefulWidget {
  const _RecordsTab({
    required this.records,
    required this.onDelete,
    required this.onDeleteBulk,
  });

  final List<PotholeRecord> records;
  final Function(int) onDelete;
  final Function(List<int>) onDeleteBulk;

  @override
  State<_RecordsTab> createState() => _RecordsTabState();
}

class _RecordsTabState extends State<_RecordsTab> {
  bool _isSelectionMode = false;
  final Set<int> _selectedIds = {};

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      _selectedIds.clear();
    });
  }

  void _toggleRecordSelection(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.records.isEmpty) {
      return const Center(
        child: Text(
          'Henüz kayıt bulunmamaktadır.',
          style: TextStyle(color: Colors.white54, fontSize: 16),
        ),
      );
    }

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Tespit Geçmişi',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                TextButton(
                  onPressed: _toggleSelectionMode,
                  child: Text(
                    _isSelectionMode ? 'İptal' : 'Seç',
                    style: const TextStyle(
                      color: Colors.blueAccent,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isSelectionMode && _selectedIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                ),
                onPressed: () {
                  widget.onDeleteBulk(_selectedIds.toList());
                  _toggleSelectionMode();
                },
                icon: const Icon(Icons.delete, color: Colors.white),
                label: Text(
                  '${_selectedIds.length} Kaydı Sil',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: widget.records.length,
              itemBuilder: (context, i) {
                final item = widget.records[i];
                final isSelected = _selectedIds.contains(item.id);
                return GestureDetector(
                  onLongPress: () {
                    if (!_isSelectionMode) {
                      _toggleSelectionMode();
                      _toggleRecordSelection(item.id);
                    }
                  },
                  onTap: () {
                    if (_isSelectionMode) {
                      _toggleRecordSelection(item.id);
                    } else {
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  DetailScreen(record: item),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: child,
                                );
                              },
                        ),
                      );
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF1E355A)
                          : const Color(0xFF101B30),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? Colors.blueAccent
                            : const Color(0xFF1A2A46),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        if (_isSelectionMode)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Checkbox(
                              value: isSelected,
                              activeColor: Colors.blueAccent,
                              onChanged: (val) {
                                _toggleRecordSelection(item.id);
                              },
                            ),
                          ),
                        Hero(
                          tag: 'record_image_${item.id}',
                          child: ClipRRect(
                            borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(_isSelectionMode ? 0 : 15),
                            ),
                            child: item.imagePath.startsWith('http')
                                ? Image.network(
                                    item.imagePath,
                                    width: 100,
                                    height: 100,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, err, stack) =>
                                        _buildPlaceholder(),
                                  )
                                : Image.asset(
                                    item.imagePath,
                                    width: 100,
                                    height: 100,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, err, stack) =>
                                        _buildPlaceholder(),
                                  ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.location,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: Colors.white,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (!_isSelectionMode)
                                      PopupMenuButton<String>(
                                        icon: const Icon(
                                          Icons.more_vert,
                                          color: Colors.white54,
                                          size: 20,
                                        ),
                                        padding: EdgeInsets.zero,
                                        onSelected: (value) {
                                          if (value == 'delete') {
                                            widget.onDelete(item.id);
                                          }
                                        },
                                        itemBuilder: (context) => [
                                          const PopupMenuItem(
                                            value: 'delete',
                                            height: 32,
                                            child: Text(
                                              'Kaydı Sil',
                                              style: TextStyle(
                                                color: Colors.redAccent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.access_time,
                                      size: 14,
                                      color: Colors.blueGrey,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${item.formattedDate} ${item.formattedTime}',
                                      style: const TextStyle(
                                        color: Colors.blueGrey,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.redAccent.withOpacity(
                                          0.2,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        'G: %${(item.confidence * 100).toStringAsFixed(1)}',
                                        style: const TextStyle(
                                          color: Colors.redAccent,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      item.size,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: 100,
      height: 100,
      color: const Color(0xFF1B2A40),
      child: const Icon(
        Icons.image_not_supported,
        color: Colors.white24,
        size: 30,
      ),
    );
  }
}

class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF111D34),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  _StatusToken(
                    icon: Icons.circle,
                    color: Colors.green,
                    text: 'YOLOv8 AI Aktif',
                  ),
                  _StatusToken(
                    icon: Icons.location_on,
                    color: Colors.white,
                    text: 'Güçlü Sinyal',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1B30),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: const Color(0xFF243A5A),
                  child: const Icon(Icons.person, size: 28),
                ),
                const SizedBox(width: 13),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Ferhat Rammok',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Öncü Sürücü',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: const [
                Expanded(
                  child: _ProfileStat(title: 'Tespit', value: '142'),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: _ProfileStat(title: 'KM Tarandı', value: '4.2k'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Karanlık Tema'),
            value: true,
            onChanged: (value) {},
            activeColor: const Color(0xFF3E8BFF),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                side: const BorderSide(color: Colors.redAccent),
              ),
              icon: const Icon(Icons.logout, color: Colors.redAccent),
              label: const Text(
                'Çıkış Yap',
                style: TextStyle(color: Colors.redAccent),
              ),
              onPressed: () {},
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({super.key, required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 90,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1526),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class DetectionScreen extends StatefulWidget {
  const DetectionScreen({super.key});

  @override
  State<DetectionScreen> createState() => _DetectionScreenState();
}

class _DetectionScreenState extends State<DetectionScreen> {
  bool isDetecting = false;
  PotholeRecord? detected;

  void _toggleDetection() {
    setState(() {
      if (isDetecting) {
        isDetecting = false;
        detected = null;
      } else {
        isDetecting = true;
        detected = sampleRecords[Random().nextInt(sampleRecords.length)];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final overlayText = isDetecting
        ? 'POTHOLE DETECTED! (%${(detected?.confidence ?? 0) * 100 ~/ 1})'
        : 'Hazır - Kamera aktif';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Canlı Tespit'),
        backgroundColor: const Color(0xFF0F162B),
      ),
      body: Column(
        children: [
          Container(
            height: 320,
            margin: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Colors.black,
              border: Border.all(color: const Color(0xFF23304D)),
            ),
            child: Stack(
              children: [
                const Center(
                  child: Text(
                    'Kamera Önizlemesi',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                if (isDetecting && detected != null) ...[
                  Positioned(
                    left: 40,
                    top: 50,
                    child: Container(
                      width: 200,
                      height: 120,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.red, width: 3),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 40,
                    top: 25,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 7,
                      ),
                      color: Colors.red.withOpacity(0.95),
                      child: Text(
                        'Çukur - %${(detected!.confidence * 100).toStringAsFixed(0)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            color: isDetecting ? Colors.redAccent : const Color(0xFF173455),
            child: Center(
              child: Text(
                overlayText,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _toggleDetection,
                    child: Text(isDetecting ? 'Durdur' : 'Tespit Başlat'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      if (detected != null) {
                        Navigator.pushNamed(
                          context,
                          '/detail',
                          arguments: detected,
                        );
                      }
                    },
                    child: const Text('Kaydet'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('İptal'),
            ),
          ),
        ],
      ),
    );
  }
}

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Harita'),
        backgroundColor: const Color(0xFF0F162B),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: const Color(0xFF0B1223),
                ),
                child: const Center(
                  child: Icon(Icons.map, size: 80, color: Colors.white24),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemBuilder: (context, index) {
                  final record = sampleRecords[index];
                  return ListTile(
                    tileColor: const Color(0xFF101B2E),
                    leading: const Icon(
                      Icons.location_on,
                      color: Colors.redAccent,
                    ),
                    title: Text(record.location),
                    subtitle: Text(
                      '${record.formattedDate} ${record.formattedTime} - ${record.size}',
                    ),
                    trailing: Text(
                      '${(record.confidence * 100).toStringAsFixed(0)}%',
                    ),
                    onTap: () => Navigator.pushNamed(
                      context,
                      '/detail',
                      arguments: record,
                    ),
                  );
                },
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemCount: sampleRecords.length,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RecordsScreen extends StatelessWidget {
  const RecordsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kayıtlar'),
        backgroundColor: const Color(0xFF0F162B),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(14),
        itemCount: sampleRecords.length,
        itemBuilder: (context, index) {
          final record = sampleRecords[index];
          return Card(
            color: const Color(0xFF0C172A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade700,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.image, color: Colors.white70),
              ),
              title: Text(
                record.location,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                '${record.formattedDate} ${record.formattedTime} • ${record.size} • %${(record.confidence * 100).toStringAsFixed(1)}',
              ),
              onTap: () =>
                  Navigator.pushNamed(context, '/detail', arguments: record),
            ),
          );
        },
      ),
    );
  }
}

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.record});

  final PotholeRecord record;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080C1A),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 350,
            pinned: true,
            backgroundColor: const Color(0xFF101B30),
            flexibleSpace: FlexibleSpaceBar(
              background: Hero(
                tag: 'record_image_${record.id}',
                child: record.imagePath.startsWith('http')
                    ? Image.network(
                        record.imagePath,
                        fit: BoxFit.cover,
                        errorBuilder: (context, err, stack) => const Icon(
                          Icons.broken_image,
                          size: 80,
                          color: Colors.white24,
                        ),
                      )
                    : Image.asset(
                        record.imagePath,
                        fit: BoxFit.cover,
                        errorBuilder: (context, err, stack) => const Icon(
                          Icons.broken_image,
                          size: 80,
                          color: Colors.white24,
                        ),
                      ),
              ),
              title: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Çukur Detayı',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              centerTitle: true,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 10),
                Text(
                  record.location,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(
                      Icons.calendar_month,
                      color: Colors.blueAccent,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${record.formattedDate} - ${record.formattedTime}',
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                Row(
                  children: [
                    Expanded(
                      child: _buildInfoCard(
                        'Güven (CNN)',
                        '%${(record.confidence * 100).toStringAsFixed(1)}',
                        Icons.analytics_outlined,
                        Colors.redAccent,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildInfoCard(
                        'Tahmini Boyut',
                        record.size,
                        Icons.straighten,
                        Colors.orangeAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                const Text(
                  'Aksiyonlar',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: ElevatedButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'KGM (Karayolları) sistemine uyarı gönderildi!',
                          ),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.report_problem, color: Colors.white),
                        SizedBox(width: 10),
                        Text(
                          'Karayollarına Bildir',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back, color: Colors.white70),
                  label: const Text(
                    'Geri Dön',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: const BorderSide(color: Colors.white24, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF101B30),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A2A46)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            offset: const Offset(0, 4),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final total = sampleRecords.length;
    final km = 4200;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
        backgroundColor: const Color(0xFF0F162B),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF101B2E),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: const Color(0xFF1E2B45),
                  child: const Icon(Icons.person, size: 34),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Ferhat Rammok',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Öncü Sürücü',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _ProfileMetric(title: 'Tespit', value: total.toString()),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ProfileMetric(title: 'KM Tarandı', value: '$km'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SwitchListTile(
            activeColor: Colors.blueAccent,
            value: true,
            onChanged: (v) {},
            title: const Text('Karanlık Tema'),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('Çıkış Yap'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.popUntil(context, (route) => route.isFirst);
            },
          ),
        ],
      ),
    );
  }
}

class _ProfileMetric extends StatelessWidget {
  const _ProfileMetric({super.key, required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 92,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1728),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class DetectionOverlay extends StatelessWidget {
  const DetectionOverlay({
    super.key,
    required this.detections,
    required this.screenSize,
    this.mediaSize,
  });

  final List<Detection> detections;
  final Size screenSize;
  final Size? mediaSize;

  @override
  Widget build(BuildContext context) {
    Size actualScreenSize = screenSize;
    double offsetX = 0;
    double offsetY = 0;

    if (mediaSize != null && mediaSize!.width > 0 && mediaSize!.height > 0) {
      final scale = min(
        screenSize.width / mediaSize!.width,
        screenSize.height / mediaSize!.height,
      );
      final renderWidth = mediaSize!.width * scale;
      final renderHeight = mediaSize!.height * scale;
      offsetX = (screenSize.width - renderWidth) / 2;
      offsetY = (screenSize.height - renderHeight) / 2;
      actualScreenSize = Size(renderWidth, renderHeight);
    }

    return Stack(
      children: detections.map((detection) {
        // normalization: backend yolluyor [0..1]
        final x1 = detection.x1;
        final y1 = detection.y1;
        final x2 = detection.x2;
        final y2 = detection.y2;
        final confidence = detection.confidence;
        final className = detection.className;

        final left = offsetX + x1 * actualScreenSize.width;
        final top = offsetY + y1 * actualScreenSize.height;
        final width = (x2 - x1) * actualScreenSize.width;
        final height = (y2 - y1) * actualScreenSize.height;

        return Positioned(
          left: left,
          top: top,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Sadece İçi Boş Çerçeve
              Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.redAccent, width: 2.5),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              // Çerçevenin Dışında (Üstünde) Etiket
              Positioned(
                top: -22,
                left: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${className} ${(confidence * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
