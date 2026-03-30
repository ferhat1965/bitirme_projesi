from ultralytics import YOLO

# Modeli yükle
model = YOLO('models/best.pt')

# TensorFlow Lite formatına çevir (int8 katsayılarıyla veya direkt default)
model.export(format='tflite')
print("TFLite dışa aktarımı başarıyla tamamlandı!")
