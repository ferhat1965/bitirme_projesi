import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../main.dart'; // Detection class import

class FrameResult {
  final List<Detection> detections;
  final String? savedImagePath;

  FrameResult({required this.detections, this.savedImagePath});
}

class TFLiteService {
  static final TFLiteService _instance = TFLiteService._();
  factory TFLiteService() => _instance;
  TFLiteService._();

  Interpreter? _interpreter;
  bool _isInit = false;

  final int _inputSize = 640;

  Future<void> init() async {
    if (_isInit) return;
    try {
      final options = InterpreterOptions()..threads = 4;
      
      try {
        if (Platform.isAndroid) {
          options.addDelegate(GpuDelegateV2());
          print('TFLite GPU Delegate V2 başarıyla eklendi.');
        } else if (Platform.isIOS) {
          options.addDelegate(GpuDelegate());
          print('TFLite Metal Delegate başarıyla eklendi.');
        }
      } catch (e) {
        print('GPU Delegate başlatılamadı, NNAPI/CPU kullanılacak: $e');
        options.useNnApiForAndroid = true;
      }
        
      _interpreter = await Interpreter.fromAsset('assets/models/best.tflite', options: options);
      _isInit = true;
      print('TFLite Modeli donanım hızlandırma ile başarıyla yüklendi!');
      print('Input shape: ${_interpreter!.getInputTensor(0).shape}');
      print('Output shape: ${_interpreter!.getOutputTensor(0).shape}');
    } catch (e) {
      print('TFLite Modeli yüklenirken hata: $e');
    }
  }

  Future<FrameResult> runFrame({
    required Uint8List yPlane,
    required int width,
    required int height,
    required int rowStride,
    required int rotation,
    bool saveImage = false,
    String? docDirPath,
  }) async {
    if (!_isInit || _interpreter == null) {
      return FrameResult(detections: [], savedImagePath: null);
    }

    try {
      return await compute(_processFrameInIsolate, {
        'yPlane': yPlane,
        'width': width,
        'height': height,
        'rowStride': rowStride,
        'rotation': rotation,
        'address': _interpreter!.address,
        'inputSize': _inputSize,
        'saveImage': saveImage,
        'docDirPath': docDirPath,
      });
    } catch (e) {
      debugPrint('TFLite Isolate Hatası (Live): $e');
      return FrameResult(detections: [
         Detection(x1: 0, y1: 0, x2: 1, y2: 1, confidence: 0.99, className: 'HATA: $e')
      ], savedImagePath: null);
    }
  }

  static Future<FrameResult> _processFrameInIsolate(Map<String, dynamic> params) async {
    final Uint8List yPlane = params['yPlane'];
    final int width = params['width'];
    final int height = params['height'];
    final int rowStride = params['rowStride'];
    final int rotation = params['rotation'];
    final int address = params['address'];
    final int size = params['inputSize'];
    final bool saveImage = params['saveImage'];
    final String? docDirPath = params['docDirPath'];

    final interpreter = Interpreter.fromAddress(address);

    int srcW = (rotation == 90 || rotation == 270) ? height : width;
    int srcH = (rotation == 90 || rotation == 270) ? width : height;

    double scaleX = srcW / size;
    double scaleY = srcH / size;

    // Hızlı bölme işlemi için tablo
    final Float32List div255Table = Float32List(256);
    for (int i = 0; i < 256; i++) {
      div255Table[i] = i / 255.0;
    }

    // Koordinat dönüşümlerini önceden hesapla (Double işlem ve Clamp sayısını azaltır)
    final Int32List mappedX = Int32List(size);
    for (int x = 0; x < size; x++) {
      mappedX[x] = (x * scaleX).toInt().clamp(0, srcW - 1);
    }
    final Int32List mappedY = Int32List(size);
    for (int y = 0; y < size; y++) {
      mappedY[y] = (y * scaleY).toInt().clamp(0, srcH - 1);
    }

    final Float32List inputBuffer = Float32List(1 * size * size * 3);
    int pIndex = 0;

    // Döngü içi "if (rotation)" sorgusunu tamamen dışarı alarak dal kontrolü (branching) optimizasyonu yapıyoruz
    switch (rotation) {
      case 90:
        for (int y = 0; y < size; y++) {
          final int ny = mappedY[y];
          final int origX = ny;
          for (int x = 0; x < size; x++) {
            final int nx = mappedX[x];
            final int origY = height - 1 - nx;
            final int offset = origY * rowStride + origX;
            final double lum = div255Table[yPlane[offset]];
            inputBuffer[pIndex++] = lum;
            inputBuffer[pIndex++] = lum;
            inputBuffer[pIndex++] = lum;
          }
        }
        break;
      case 270:
        for (int y = 0; y < size; y++) {
          final int ny = mappedY[y];
          final int origX = width - 1 - ny;
          for (int x = 0; x < size; x++) {
            final int nx = mappedX[x];
            final int origY = nx;
            final int offset = origY * rowStride + origX;
            final double lum = div255Table[yPlane[offset]];
            inputBuffer[pIndex++] = lum;
            inputBuffer[pIndex++] = lum;
            inputBuffer[pIndex++] = lum;
          }
        }
        break;
      case 180:
        for (int y = 0; y < size; y++) {
          final int ny = mappedY[y];
          final int origY = height - 1 - ny;
          for (int x = 0; x < size; x++) {
            final int nx = mappedX[x];
            final int origX = width - 1 - nx;
            final int offset = origY * rowStride + origX;
            final double lum = div255Table[yPlane[offset]];
            inputBuffer[pIndex++] = lum;
            inputBuffer[pIndex++] = lum;
            inputBuffer[pIndex++] = lum;
          }
        }
        break;
      default: // 0
        for (int y = 0; y < size; y++) {
          final int ny = mappedY[y];
          final int origY = ny;
          for (int x = 0; x < size; x++) {
            final int nx = mappedX[x];
            final int origX = nx;
            final int offset = origY * rowStride + origX;
            final double lum = div255Table[yPlane[offset]];
            inputBuffer[pIndex++] = lum;
            inputBuffer[pIndex++] = lum;
            inputBuffer[pIndex++] = lum;
          }
        }
        break;
    }

    final outputShape = interpreter.getOutputTensor(0).shape;
    final int outSize = outputShape.fold(1, (a, b) => a * b);
    final Float32List outputBuffer = Float32List(outSize);

    interpreter.runForMultipleInputs(
      [inputBuffer.buffer],
      {0: outputBuffer.buffer},
    );

    final detections = _parseOutput1D(outputBuffer, outputShape, size, srcW, srcH);
    
    String? savedPath;
    if (saveImage && detections.isNotEmpty && docDirPath != null) {
      final bestDet = detections.reduce((a, b) => a.confidence > b.confidence ? a : b);
      if (bestDet.confidence >= 0.45) {
        img.Image image = img.Image(width: width, height: height, numChannels: 3);
        for (int yy = 0; yy < height; yy++) {
          int offset = yy * rowStride;
          for (int xx = 0; xx < width; xx++) {
            final lum = yPlane[offset + xx];
            image.setPixelRgb(xx, yy, lum, lum, lum);
          }
        }
        img.Image rotatedImage = image;
        if (rotation == 90) {
          rotatedImage = img.copyRotate(image, angle: 90);
        } else if (rotation == 270) {
          rotatedImage = img.copyRotate(image, angle: 270);
        } else if (rotation == 180) {
          rotatedImage = img.copyRotate(image, angle: 180);
        }

        savedPath = '$docDirPath/pothole_live_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(savedPath).writeAsBytes(img.encodeJpg(rotatedImage));
      }
    }

    return FrameResult(detections: detections, savedImagePath: savedPath);
  }

  Future<List<Detection>> runImage(String imagePath) async {
    if (!_isInit) await init();

    if (_interpreter == null) return [];

    try {
      return await compute(_processInIsolate, {
        'imagePath': imagePath,
        'address': _interpreter!.address,
        'inputSize': _inputSize,
      });
    } catch (e) {
      debugPrint('TFLite Isolate Hatası: $e');
      return [
         Detection(x1: 0, y1: 0, x2: 1, y2: 1, confidence: 0.99, className: 'HATA: $e')
      ];
    }
  }

  static Future<List<Detection>> _processInIsolate(Map<String, dynamic> params) async {
    final String imagePath = params['imagePath'];
    final int address = params['address'];
    final int size = params['inputSize'];

    final interpreter = Interpreter.fromAddress(address);
    final bytes = await File(imagePath).readAsBytes();
    final rawImage = img.decodeImage(bytes);
    if (rawImage == null) return [];

    final image = img.bakeOrientation(rawImage);
    final inputImage = img.copyResize(image, width: size, height: size);

    // Düşük bellek tüketimi için Native Buffer optimizasyonu eklendi
    final Float32List inputBuffer = Float32List(1 * size * size * 3);
    final Uint8List rgbBytes = inputImage.getBytes(order: img.ChannelOrder.rgb);

    for (int i = 0; i < inputBuffer.length; i += 3) {
      double r = rgbBytes[i] / 255.0;
      double g = rgbBytes[i + 1] / 255.0;
      double b = rgbBytes[i + 2] / 255.0;

      double lum = (0.299 * r) + (0.587 * g) + (0.114 * b);

      inputBuffer[i] = lum;
      inputBuffer[i + 1] = lum;
      inputBuffer[i + 2] = lum;
    }

    final outputShape = interpreter.getOutputTensor(0).shape;
    final int outSize = outputShape.fold(1, (a, b) => a * b);
    final Float32List outputBuffer = Float32List(outSize);

    interpreter.runForMultipleInputs(
      [inputBuffer.buffer],
      {0: outputBuffer.buffer},
    );

    return _parseOutput1D(outputBuffer, outputShape, size, inputImage.width, inputImage.height);
  }

  static List<Detection> _parseOutput1D(Float32List outputBuffer, List<int> shape, int inputSize, int originalWidth, int originalHeight) {
    List<Detection> list = [];
    final threshold = 0.45;

    if (shape.length < 3) return list;

    int numClassesAndBbox = shape[1];
    int numBoxes = shape[2];
    bool isFormatA = true;

    if (shape[1] > 1000) {
      numClassesAndBbox = shape[2];
      numBoxes = shape[1];
      isFormatA = false;
    }

    int numClasses = numClassesAndBbox - 4;
    if (numClasses < 1) numClasses = 1;

    for (int i = 0; i < numBoxes; i++) {
      double maxClassConf = -1.0;
      int maxClassIndex = -1;

      for (int c = 0; c < numClasses; c++) {
        int cIndex = 4 + c;
        double conf = isFormatA 
            ? outputBuffer[cIndex * numBoxes + i] 
            : outputBuffer[i * numClassesAndBbox + cIndex];
            
        if (conf > maxClassConf) {
          maxClassConf = conf;
          maxClassIndex = c;
        }
      }
      
      if (maxClassConf > threshold) {
        double xc = isFormatA ? outputBuffer[0 * numBoxes + i] : outputBuffer[i * numClassesAndBbox + 0];
        double yc = isFormatA ? outputBuffer[1 * numBoxes + i] : outputBuffer[i * numClassesAndBbox + 1];
        double w  = isFormatA ? outputBuffer[2 * numBoxes + i] : outputBuffer[i * numClassesAndBbox + 2];
        double h  = isFormatA ? outputBuffer[3 * numBoxes + i] : outputBuffer[i * numClassesAndBbox + 3];

        double effectiveDivisor = (xc <= 2.0 && yc <= 2.0) ? 1.0 : inputSize.toDouble();

        double nx1 = (xc - w / 2) / effectiveDivisor;
        double ny1 = (yc - h / 2) / effectiveDivisor;
        double nx2 = (xc + w / 2) / effectiveDivisor;
        double ny2 = (yc + h / 2) / effectiveDivisor;

        nx1 = nx1.clamp(0.0, 1.0);
        ny1 = ny1.clamp(0.0, 1.0);
        nx2 = nx2.clamp(0.0, 1.0);
        ny2 = ny2.clamp(0.0, 1.0);

        String detectedClass = 'Çukur';
        if (numClasses > 1) {
           if (maxClassIndex == 0) detectedClass = 'Hafif Çukur';
           else if (maxClassIndex == 1) detectedClass = 'Orta Çukur';
           else if (maxClassIndex == 2) detectedClass = 'Derin Çukur';
           else if (maxClassIndex == 3) detectedClass = 'Kasis';
           else detectedClass = 'Sınıf $maxClassIndex';
        }

        list.add(Detection(
          x1: nx1,
          y1: ny1,
          x2: nx2,
          y2: ny2,
          confidence: maxClassConf,
          className: detectedClass,
        ));
      }
    }

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
