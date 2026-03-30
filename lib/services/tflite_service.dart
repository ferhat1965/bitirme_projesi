import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
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
    if (!_isInit || _interpreter == null) {
      await init();
      if (!_isInit || _interpreter == null) {
         throw Exception("Model başlatılamadı!\nSebep: $_initError\n(Uygulamayı tamamen kapatıp açmayı deneyin)");
      }
    }

    final bytes = await File(imagePath).readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return [];

    return _processImage(image);
  }

  Future<List<Detection>> runFrame(CameraImage cameraImage) async {
    if (!_isInit || _interpreter == null) return [];

    // CameraImage -> Image convert (basit YUV420 dönüşümü)
    // Gerçek performans için platform-channel (Native) kullanılabilir.
    // Şimdilik dart üzerinden basit dönüşüm veya sadece bytes gönderimi yapılabilir
    return []; // TODO: Camera frame conversion processing 
  }

  Future<List<Detection>> _processImage(img.Image image) async {
      final inputImage = img.copyResize(image, width: _inputSize, height: _inputSize);
      
      // Görüntüyü Tensor formuna dönüştür. (Float32, [1, 640, 640, 3])
      var input = List.generate(
        1,
        (i) => List.generate(
          _inputSize,
          (y) => List.generate(
            _inputSize,
            (x) {
              final pixel = inputImage.getPixel(x, y);
              return [
                pixel.r / 255.0,
                pixel.g / 255.0,
                pixel.b / 255.0
              ];
            },
          ),
        ),
      );

      final outputShape = _interpreter!.getOutputTensor(0).shape;
      
      // Çıktı formatını modele tam entegre et:
      // YOLOv8 için genelde [1, 5, 8400] ama export parametresine göre [1, 8400, 5] olabilir
      var output = List.generate(
        outputShape[0],
        (i) => List.generate(
          outputShape[1],
          (j) => List.generate(
             outputShape[2],
             (k) => 0.0
          ),
        ),
      );

      try {
        _interpreter!.run(input, output);
        return _parseOutput(output, outputShape, image.width, image.height);
      } catch (e) {
        throw Exception('Shape Hatası:\nModel Shape: ${outputShape}\nHata: $e');
      }
  }

  List<Detection> _parseOutput(List<dynamic> rawOutput, List<int> shape, int originalWidth, int originalHeight) {
    List<Detection> list = [];
    final threshold = 0.25;

    final out = rawOutput[0] as List<dynamic>; 
    
    // Eğer beklediğimiz YOLOv8 boyutunda değilse (num_classes + 4 sayısı 5 değilse, örneğin 80 classlı bir modelse)
    if (shape.length < 3) throw Exception("Bilinmeyen Model Şekli: ${shape}");
    
    int numClassesAndBbox = shape[1];
    int numBoxes = shape[2];
    bool isFormatA = true;
    
    if (shape[1] > 1000) { // [1, 8400, 5] gibi ters matrix
        numClassesAndBbox = shape[2];
        numBoxes = shape[1];
        isFormatA = false;
    }

    // Güven (Confidence) indexi genelde 4'tür (x,y,w,h, conf)
    int confIndex = 4;
    if (numClassesAndBbox != 5) {
       // Eğitim farklı verilmiş olabilir, fırlatıp UI'da boyutunu görelim:
       throw Exception("Beklenmeyen Sınıf Sayısı: shape[1]=$numClassesAndBbox (Tahminimce ${numClassesAndBbox-4} class var)\nModel Şekli: $shape");
    }

    for (int i = 0; i < numBoxes; i++) {
        double confidence = isFormatA ? (out[confIndex][i] as double) : (out[i][confIndex] as double);
        if (confidence > threshold) {
            double xc = isFormatA ? (out[0][i] as double) : (out[i][0] as double);
            double yc = isFormatA ? (out[1][i] as double) : (out[i][1] as double);
            double w  = isFormatA ? (out[2][i] as double) : (out[i][2] as double);
            double h  = isFormatA ? (out[3][i] as double) : (out[i][3] as double);

            // Normalize Koordinatlar YOLO Formatı
            double nx1 = (xc - w / 2) / _inputSize;
            double ny1 = (yc - h / 2) / _inputSize;
            double nx2 = (xc + w / 2) / _inputSize;
            double ny2 = (yc + h / 2) / _inputSize;

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

  List<Detection> applyNms(List<Detection> boxes, double iouThreshold) {
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

  double _calculateIou(Detection a, Detection b) {
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
