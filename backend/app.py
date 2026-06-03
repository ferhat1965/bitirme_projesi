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

# Ultralytics YOLOv11 için
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
    # YOLOv11 model
    model = YOLO(str(MODEL_PATH))
    model_type = 'yolo'
    print(f"YOLOv11 model yüklendi: {MODEL_PATH}")
else:
    raise FileNotFoundError(f"Model dosyası bulunamadı veya desteklenmiyor: {MODEL_PATH}. YOLOv11 (.pt) veya TensorFlow Lite (.tflite) dosyası gerekli.")

def detect_with_tflite(image: Image.Image):
    """TensorFlow Lite ile tespit (YOLOv11 çıkış formatını destekler)"""
    input_details = model.get_input_details()
    output_details = model.get_output_details()

    # Model input properties
    input_shape = input_details[0]['shape']
    input_height = input_shape[1] if input_shape[3] == 3 else input_shape[2]
    input_width = input_shape[2] if input_shape[3] == 3 else input_shape[3]
    is_chw = input_shape[1] == 3 or input_shape[1] == 1
    
    is_float = input_details[0]['dtype'] == np.float32

    # Resize image
    img = image.resize((input_width, input_height))
    img_array = np.array(img, dtype=np.float32 if is_float else np.uint8)
    
    if is_float:
        img_array = img_array / 255.0

    # Grayscale check
    if input_shape[3] == 1 or (is_chw and input_shape[1] == 1):
        img_gray = img.convert('L')
        img_array = np.array(img_gray, dtype=np.float32 if is_float else np.uint8)
        if is_float:
            img_array = img_array / 255.0
        img_array = np.expand_dims(img_array, axis=-1)

    if is_chw:
        if len(img_array.shape) == 3:
            img_array = np.transpose(img_array, (2, 0, 1))
        
    img_array = np.expand_dims(img_array, axis=0)

    # Set tensor and run
    model.set_tensor(input_details[0]['index'], img_array)
    model.invoke()

    # Get results dynamically
    if len(output_details) > 1:
        # SSD Mobilenet format (multiple output tensors)
        boxes_idx = 0
        classes_idx = 1
        scores_idx = 2
        
        for det in output_details:
            shape = det['shape']
            if len(shape) == 3 and shape[2] == 4:
                boxes_idx = det['index']
            elif len(shape) == 2:
                if 'class' in det['name'].lower():
                    classes_idx = det['index']
                elif 'score' in det['name'].lower():
                    scores_idx = det['index']
        
        try:
            boxes = model.get_tensor(boxes_idx)
            classes = model.get_tensor(classes_idx)
            scores = model.get_tensor(scores_idx)
        except Exception:
            boxes = model.get_tensor(output_details[0]['index'])
            classes = model.get_tensor(output_details[1]['index'])
            scores = model.get_tensor(output_details[2]['index'])

        detections = []
        for i in range(len(scores[0])):
            if scores[0][i] > 0.25:
                ymin, xmin, ymax, xmax = boxes[0][i]
                class_id = int(classes[0][i])
                
                class_names = {
                    0: 'minor_pothole',
                    1: 'medium_pothole',
                    2: 'major_pothole',
                    3: 'speed_bump'
                }
                c_name = class_names.get(class_id, 'pothole')

                detections.append({
                    'bbox': [max(0.0, min(1.0, xmin)), max(0.0, min(1.0, ymin)), max(0.0, min(1.0, xmax)), max(0.0, min(1.0, ymax))],
                    'confidence': float(scores[0][i]),
                    'class': c_name,
                })
        return detections
    else:
        # YOLO format (single output tensor)
        output = model.get_tensor(output_details[0]['index'])
        output = np.squeeze(output)
        
        if len(output.shape) == 2:
            if output.shape[0] > output.shape[1]:
                output = np.transpose(output)
                
        num_classes = output.shape[0] - 4
        num_boxes = output.shape[1]
        
        class_names = {
            0: 'minor_pothole',
            1: 'medium_pothole',
            2: 'major_pothole',
            3: 'speed_bump'
        }
        
        raw_boxes = []
        scores = []
        class_ids = []
        
        for i in range(num_boxes):
            box_scores = output[4:, i]
            class_id = np.argmax(box_scores)
            score = box_scores[class_id]
            
            if score > 0.25:
                xc = output[0, i]
                yc = output[1, i]
                w = output[2, i]
                h = output[3, i]
                
                divisor_w = 1.0 if xc <= 2.0 else float(input_width)
                divisor_h = 1.0 if yc <= 2.0 else float(input_height)
                
                x1 = (xc - w / 2.0) / divisor_w
                y1 = (yc - h / 2.0) / divisor_h
                x2 = (xc + w / 2.0) / divisor_w
                y2 = (yc + h / 2.0) / divisor_h
                
                raw_boxes.append([
                    max(0.0, min(1.0, x1)),
                    max(0.0, min(1.0, y1)),
                    max(0.0, min(1.0, x2)),
                    max(0.0, min(1.0, y2))
                ])
                scores.append(float(score))
                class_ids.append(int(class_id))
                
        detections = []
        if len(raw_boxes) > 0:
            nms_boxes = []
            for box in raw_boxes:
                nms_boxes.append([box[0], box[1], box[2] - box[0], box[3] - box[1]])
                
            indices = cv2.dnn.NMSBoxes(nms_boxes, scores, 0.25, 0.45)
            if len(indices) > 0:
                indices = indices.flatten() if hasattr(indices, 'flatten') else indices
                for idx in indices:
                    c_id = class_ids[idx]
                    c_name = class_names.get(c_id, f"class_{c_id}")
                    detections.append({
                        'bbox': raw_boxes[idx],
                        'confidence': scores[idx],
                        'class': c_name
                    })
        return detections

def detect_with_yolo(image: Image.Image):
    """YOLOv11 ile tespit"""
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
