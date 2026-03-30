import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../main.dart'; // Detection class import

class TFLiteService {
  static final TFLiteService _instance = TFLiteService._();
  factory TFLiteService() => _instance;
  TFLiteService._();

  Interpreter? _interpreter;
  bool _isInit = false;
  String? _initError;

  final int _inputSize = 640;

  Future<void> init() async {
    if (_isInit) return;
    try {
      _interpreter = await Interpreter.fromAsset('assets/models/best.tflite');
      _isInit = true;
      _initError = null;
      print('TFLite Modeli başarıyla yüklendi!');
      print('Input shape: ${_interpreter!.getInputTensor(0).shape}');
      print('Output shape: ${_interpreter!.getOutputTensor(0).shape}');
    } catch (e) {
      _initError = e.toString();
      print('TFLite Modeli yüklenirken hata: $e');
    }
  }

  Future<List<Detection>> runImage(String imagePath) async {
    if (!_isInit) await init();

    if (_interpreter == null) return [];

    try {
      // Bütün ağır işlemleri (Resim okuma, List oluşturma, TFLite yorumlama) Isolate içine atıyoruz
      // Böylece Canlı kamerada saniyede 4 kez çağrılsa bile telefon kesinlikle çökmeyecek.
      return await compute(_processInIsolate, {
        'imagePath': imagePath,
        'address': _interpreter!.address,
        'inputSize': _inputSize,
      });
    } catch (e) {
      debugPrint('TFLite Isolate Hatası: $e');
      return [];
    }
  }

  static Future<List<Detection>> _processInIsolate(Map<String, dynamic> params) async {
    final String imagePath = params['imagePath'];
    final int address = params['address'];
    final int size = params['inputSize'];

    // Arka planda modeli adresten tekrar ayağa kaldırıyoruz
    final interpreter = Interpreter.fromAddress(address);

    final bytes = await File(imagePath).readAsBytes();
    final rawImage = img.decodeImage(bytes);
    if (rawImage == null) return [];

    // EXIF Rotation problemlerini çözer (Yatay çekilen resimlerin UI'da dikey analiz edilmesi sorunu)
    final image = img.bakeOrientation(rawImage);

    // Görüntüyü YOLOv8 giriş boyutuna göre kare yapıyoruz
    final inputImage = img.copyResize(image, width: size, height: size);

    // [1, 640, 640, 3] Tensor formati
    var input = List.generate(
      1,
      (i) => List.generate(
        size,
        (y) => List.generate(
          size,
          (x) {
            final pixel = inputImage.getPixel(x, y);
            return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
          },
        ),
      ),
    );

    final outputShape = interpreter.getOutputTensor(0).shape;

    var output = List.generate(
      outputShape[0],
      (i) => List.generate(
        outputShape[1],
        (j) => List.generate(outputShape[2], (k) => 0.0),
      ),
    );

    interpreter.run(input, output);

    return _parseOutput(output, outputShape, size, image.width, image.height);
  }

  static List<Detection> _parseOutput(List<dynamic> rawOutput, List<int> shape, int inputSize, int originalWidth, int originalHeight) {
    List<Detection> list = [];
    final threshold = 0.25;

    final out = rawOutput[0] as List<dynamic>;

    if (shape.length < 3) return list;

    int numClassesAndBbox = shape[1];
    int numBoxes = shape[2];
    bool isFormatA = true;

    if (shape[1] > 1000) {
      numClassesAndBbox = shape[2];
      numBoxes = shape[1];
      isFormatA = false;
    }

    int confIndex = 4;
    for (int i = 0; i < numBoxes; i++) {
      double confidence = isFormatA ? (out[confIndex][i] as double) : (out[i][confIndex] as double);
      if (confidence > threshold) {
        double xc = isFormatA ? (out[0][i] as double) : (out[i][0] as double);
        double yc = isFormatA ? (out[1][i] as double) : (out[i][1] as double);
        double w = isFormatA ? (out[2][i] as double) : (out[i][2] as double);
        double h = isFormatA ? (out[3][i] as double) : (out[i][3] as double);

        // Normalize edilmiş YOLO koordinatları
        double nx1 = (xc - w / 2) / inputSize;
        double ny1 = (yc - h / 2) / inputSize;
        double nx2 = (xc + w / 2) / inputSize;
        double ny2 = (yc + h / 2) / inputSize;

        list.add(Detection(
          x1: nx1,
          y1: ny1,
          x2: nx2,
          y2: ny2,
          confidence: confidence,
          className: 'pothole',
        ));
      }
    }

    // NMS (Non-Maximum Suppression) gerekli olabilir
    return applyNms(list, 0.45);
  }

  static List<Detection> applyNms(List<Detection> boxes, double iouThreshold) {
    if (boxes.isEmpty) return [];

    boxes.sort((a, b) => b.confidence.compareTo(a.confidence));
    List<Detection> selected = [];

    while (boxes.isNotEmpty) {
      final best = boxes.first;
      selected.add(best);
      boxes.removeAt(0);

      boxes.removeWhere((box) {
        return _calculateIou(best, box) > iouThreshold;
      });
    }

    return selected;
  }

  static double _calculateIou(Detection a, Detection b) {
    final interX1 = a.x1 > b.x1 ? a.x1 : b.x1;
    final interY1 = a.y1 > b.y1 ? a.y1 : b.y1;
    final interX2 = a.x2 < b.x2 ? a.x2 : b.x2;
    final interY2 = a.y2 < b.y2 ? a.y2 : b.y2;

    if (interX1 < interX2 && interY1 < interY2) {
      final interArea = (interX2 - interX1) * (interY2 - interY1);
      final areaA = (a.x2 - a.x1) * (a.y2 - a.y1);
      final areaB = (b.x2 - b.x1) * (b.y2 - b.y1);
      return interArea / (areaA + areaB - interArea);
    }
    return 0.0;
  }
}
