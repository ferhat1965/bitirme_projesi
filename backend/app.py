import io
import json
import os
import uuid
from datetime import datetime
from pathlib import Path
from typing import List, Optional

import cv2
import numpy as np
from dotenv import load_dotenv
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from PIL import Image, ImageOps
from sqlmodel import Field, Session, SQLModel, create_engine, select

# TensorFlow Lite için
try:
    import tflite_runtime.interpreter as tflite
    TFLITE_AVAILABLE = True
except ImportError:
    TFLITE_AVAILABLE = False

# Ultralytics YOLOv8 için
try:
    from ultralytics import YOLO
    YOLO_AVAILABLE = True
except ImportError:
    YOLO_AVAILABLE = False

load_dotenv()

MODEL_PATH = Path(os.getenv('MODEL_PATH', 'models/best.pt'))
STORAGE_DIR = Path(os.getenv('STORAGE_DIR', 'storage'))
DATABASE_URL = os.getenv('DATABASE_URL', 'sqlite:///records.db')
STORAGE_DIR.mkdir(parents=True, exist_ok=True)

# Model yükleme
model = None
model_type = None

if MODEL_PATH.suffix == '.tflite' and TFLITE_AVAILABLE:
    # TensorFlow Lite model
    model = tflite.Interpreter(model_path=str(MODEL_PATH))
    model.allocate_tensors()
    model_type = 'tflite'
    print(f"TensorFlow Lite model yüklendi: {MODEL_PATH}")
elif MODEL_PATH.suffix == '.pt' and YOLO_AVAILABLE:
    # YOLOv8 model
    model = YOLO(str(MODEL_PATH))
    model_type = 'yolo'
    print(f"YOLOv8 model yüklendi: {MODEL_PATH}")
else:
    raise FileNotFoundError(f"Model dosyası bulunamadı veya desteklenmiyor: {MODEL_PATH}. YOLOv8 (.pt) veya TensorFlow Lite (.tflite) dosyası gerekli.")

def detect_with_tflite(image: Image.Image):
    """TensorFlow Lite ile tespit"""
    # Input tensor bilgilerini al
    input_details = model.get_input_details()
    output_details = model.get_output_details()

    # Görüntüyü hazırla
    img = image.resize((320, 320))  # YOLOv8 Tiny için tipik boyut
    img_array = np.array(img, dtype=np.uint8)
    img_array = np.expand_dims(img_array, axis=0)

    # Tensörü ayarla ve çıkarım yap
    model.set_tensor(input_details[0]['index'], img_array)
    model.invoke()

    # Sonuçları al
    boxes = model.get_tensor(output_details[0]['index'])
    classes = model.get_tensor(output_details[1]['index'])
    scores = model.get_tensor(output_details[2]['index'])

    detections = []
    for i in range(len(scores[0])):
        if scores[0][i] > 0.25:  # confidence threshold
            ymin, xmin, ymax, xmax = boxes[0][i]
            class_id = int(classes[0][i])

            # Normalize coordinates
            nx1 = max(0.0, min(1.0, xmin))
            ny1 = max(0.0, min(1.0, ymin))
            nx2 = max(0.0, min(1.0, xmax))
            ny2 = max(0.0, min(1.0, ymax))

            detections.append({
                'bbox': [nx1, ny1, nx2, ny2],
                'confidence': float(scores[0][i]),
                'class': 'pothole',  # TFLite modelinde class name olmayabilir
            })

    return detections

def detect_with_yolo(image: Image.Image):
    """YOLOv8 ile tespit"""
    results = model(image, imgsz=640, conf=0.25, iou=0.45)
    detections = []

    for r in results:
        if r.boxes is None:
            continue
        for box in r.boxes.data.tolist():
            x1, y1, x2, y2, conf, cls = box
            class_name = model.names[int(cls)] if model.names and int(cls) in model.names else str(int(cls))

            width, height = image.size
            # normalize coords
            nx1 = max(0.0, min(1.0, x1 / width))
            ny1 = max(0.0, min(1.0, y1 / height))
            nx2 = max(0.0, min(1.0, x2 / width))
            ny2 = max(0.0, min(1.0, y2 / height))

            detections.append({
                'bbox': [nx1, ny1, nx2, ny2],
                'confidence': float(conf),
                'class': class_name,
            })

    return detections

engine = create_engine(DATABASE_URL, echo=False)

class PotholeRecord(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    detected_at: datetime
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    confidence: float
    class_name: str
    image_path: str
    bbox: str  # JSON string olarak depolayacağız

class PredictionResponse(BaseModel):
    image_id: str
    detections: List[dict]
    media_width: Optional[int] = None
    media_height: Optional[int] = None

class DeleteRecordsRequest(BaseModel):
    record_ids: List[int]

class RecordResponse(BaseModel):
    id: int
    detected_at: datetime
    latitude: Optional[float]
    longitude: Optional[float]
    confidence: float
    class_name: str
    image_url: str
    bbox: List[float]

app = FastAPI(title='RoadGuard Backend', version='1.0')

app.add_middleware(
    CORSMiddleware,
    allow_origins=['*'],
    allow_credentials=True,
    allow_methods=['*'],
    allow_headers=['*'],
)

@app.on_event('startup')
def on_startup():
    SQLModel.metadata.create_all(engine)

@app.get('/health')
def health():
    return {'status': 'ok', 'model': str(MODEL_PATH)}

@app.post('/predict', response_model=PredictionResponse)
async def predict(file: UploadFile = File(...), latitude: Optional[float] = None, longitude: Optional[float] = None, save_record: bool = True):
    if not file.filename.lower().endswith(('jpg','jpeg','png','bmp','webp')):
        raise HTTPException(status_code=400, detail='Geçersiz dosya türü. Resim yükleyin.')

    contents = await file.read()
    try:
        image = Image.open(io.BytesIO(contents)).convert('RGB')
        image = ImageOps.exif_transpose(image)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Resim açılamadı: {e}")

    unique_id = str(uuid.uuid4())
    output_name = STORAGE_DIR / f'{unique_id}.jpg'
    image.save(output_name, format="JPEG", quality=90)

    # Model türüne göre tespit yap
    if model_type == 'tflite':
        detections = detect_with_tflite(image)
    elif model_type == 'yolo':
        detections = detect_with_yolo(image)
    else:
        raise HTTPException(status_code=500, detail="Model yüklenemedi")

    # Veritabanına kaydet
    if save_record:
        for det in detections:
            with Session(engine) as session:
                rec = PotholeRecord(
                    detected_at=datetime.utcnow(),
                    latitude=latitude,
                    longitude=longitude,
                    confidence=det['confidence'],
                    class_name=det['class'],
                    image_path=str(output_name),
                    bbox=json.dumps(det['bbox']),
                )
                session.add(rec)
                session.commit()
                session.refresh(rec)

    return PredictionResponse(
        image_id=unique_id, 
        detections=detections, 
        media_width=image.width, 
        media_height=image.height
    )

@app.post('/predict_video', response_model=PredictionResponse)
async def predict_video(file: UploadFile = File(...), latitude: Optional[float] = None, longitude: Optional[float] = None):
    if not file.filename.lower().endswith(('mp4','avi','mov','mkv')):
        raise HTTPException(status_code=400, detail='Geçersiz dosya türü. Video yükleyin.')

    contents = await file.read()
    unique_id = str(uuid.uuid4())
    video_path = STORAGE_DIR / f'{unique_id}.mp4'
    with open(video_path, 'wb') as f:
        f.write(contents)

    # Video'yu OpenCV ile aç
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise HTTPException(status_code=400, detail='Video açılamadı')

    detections = []
    frame_count = 0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    video_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    video_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        frame_count += 1

        # Her 30 frame'de bir analiz yap (performans için)
        if frame_count % 30 == 0:
            # Frame'i PIL Image'a çevir
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            image = Image.fromarray(frame_rgb)

            # Model türüne göre tespit yap
            if model_type == 'tflite':
                frame_detections = detect_with_tflite(image)
            elif model_type == 'yolo':
                frame_detections = detect_with_yolo(image)
            else:
                continue

            for det in frame_detections:
                det['frame'] = frame_count
                detections.append(det)

    cap.release()

    # En güvenilir detection'ları kaydet (confidence > 0.5)
    high_conf_detections = [d for d in detections if d['confidence'] > 0.5]

    # Video araması veritabanına kaydedilmeyecektir (sadece anlık UI kullanımı için).
    # high_conf_detections listesi direkt Flutter'a dönülür.

    return PredictionResponse(
        image_id=unique_id, 
        detections=high_conf_detections,
        media_width=video_width,
        media_height=video_height
    )

@app.get('/records', response_model=List[RecordResponse])
def get_records():
    with Session(engine) as session:
        rows = session.exec(select(PotholeRecord).order_by(PotholeRecord.detected_at.desc())).all()
    return [RecordResponse(
        id=r.id,
        detected_at=r.detected_at,
        latitude=r.latitude,
        longitude=r.longitude,
        confidence=r.confidence,
        class_name=r.class_name,
        image_url=f'/storage/{Path(r.image_path).name}',
        bbox=json.loads(r.bbox),
    ) for r in rows]

@app.delete('/records/{record_id}')
def delete_record(record_id: int):
    with Session(engine) as session:
        record = session.get(PotholeRecord, record_id)
        if not record:
            raise HTTPException(status_code=404, detail="Kayıt bulunamadı")
        session.delete(record)
        session.commit()
    return {"message": "Kayıt başarıyla silindi"}

@app.delete('/records/bulk/delete')
def delete_records_bulk(req: DeleteRecordsRequest):
    with Session(engine) as session:
        session.query(PotholeRecord).filter(PotholeRecord.id.in_(req.record_ids)).delete(synchronize_session=False)
        session.commit()
    return {"message": f"{len(req.record_ids)} kayıt silindi"}

@app.get('/storage/{filename}')
def view_image(filename: str):
    path = STORAGE_DIR / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail='Dosya bulunamadı')
    return FileResponse(str(path))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
