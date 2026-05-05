# RoadGuard AI: Gerçek Zamanlı Yol Kusuru Tespit ve Haritalama Sistemi

Bu rapor, RoadGuard AI projesinin teknik altyapısını, kullanılan teknolojileri, sistem mimarisini ve çalışma prensiplerini detaylandırmak amacıyla hazırlanmıştır.

---

## 1. Proje Özeti
RoadGuard AI, sürücü güvenliğini artırmak ve yol bakım süreçlerini otomatize etmek amacıyla geliştirilmiş mobil tabanlı bir yapay zeka çözümüdür. Sistem, araç kamerasından gelen canlı görüntüyü analiz ederek yoldaki çukurları (potholes) gerçek zamanlı olarak tespit eder, GPS konumlarıyla eşleştirir ve merkezi/yerel bir veritabanına kaydeder.

---

## 2. Kullanılan Teknolojiler ve Kütüphaneler

### 2.1. Mobil Uygulama (Frontend - Flutter)
Kullanıcı arayüzü ve gerçek zamanlı işlem yönetimi için Google'ın **Flutter** SDK'sı kullanılmıştır.
*   **Arayüz (UI):** Material Design prensiplerine uygun, modern ve dinamik bir tasarım.
*   **Kamera Yönetimi:** `camera` kütüphanesi ile yüksek FPS'li canlı görüntü akışı.
*   **Yapay Zeka (On-Device ML):** `tflite_flutter` kütüphanesi ile YOLOv8 modelinin cihaz üzerinde çalıştırılması.
*   **Konum Servisleri:** `geolocator` ve `geocoding` ile hassas GPS verisinin alınması.
*   **Haritalama:** `flutter_map` (OpenStreetMap tabanlı) ile tespit edilen noktaların görselleştirilmesi.
*   **Veritabanı:** `sqflite` (SQLite wrapper) ile çevrimdışı veri saklama.

### 2.2. Sunucu Tarafı (Backend - FastAPI)
Veri senkronizasyonu ve gelişmiş analizler için Python tabanlı bir backend mimarisi oluşturulmuştur.
*   **Framework:** `FastAPI` (Yüksek performanslı, asenkron API sunucusu).
*   **Görüntü İşleme:** `OpenCV` ve `Pillow`.
*   **Yapay Zeka (Server-Side):** `ultralytics` (YOLOv8) ve `tflite-runtime`.
*   **ORM / Veritabanı:** `SQLModel` (SQLAlchemy tabanlı) ve `SQLite`.

### 2.3. Yapay Zeka Modeli
*   **Mimari:** YOLOv8 (You Only Look Once) - Nesne tespiti alanında dünyanın en hızlı ve en doğru sonuç veren mimarilerinden biridir.
*   **Format:** `.pt` (PyTorch) ve mobile optimize edilmiş `.tflite` (TensorFlow Lite).

---

## 3. Sistem Mimarisi ve Çalışma Prensibi

RoadGuard AI, hibrit bir mimari kullanarak hem cihaz üzerinde (edge computing) hem de bulutta çalışabilmektedir.

### 3.1. Akış Şeması
1.  **Görüntü Yakalama:** Mobil uygulama kameradan saniyede 30 kare (FPS) görüntü alır.
2.  **Önişleme:** Alınan kareler YOLOv8 modelinin beklediği boyuta (örn. 640x640 veya 320x320) yeniden boyutlandırılır.
3.  **Çıkarım (Inference):** 
    *   Görüntü, TensorFlow Lite motoru üzerinden C++ tabanlı native kütüphanelere gönderilir.
    *   Yapay zeka modeli, görüntüdeki nesne adaylarını tarar ve çukur olanları tespit eder.
4.  **Koordinat Dönüşümü:** Tespit edilen "Bounding Box" (sınırlayıcı kutu) koordinatları, ekran çözünürlüğüne uygun hale getirilir.
5.  **Veri Kaydı:** Tespit edilen çukurun;
    *   Fotoğrafı,
    *   Doğruluk oranı (Confidence Score),
    *   Tarih/Saat bilgisi,
    *   GPS Koordinatları (Enlem/Boylam),
    yerel SQLite veritabanına ve eşzamanlı olarak FastAPI sunucusuna kaydedilir.

---

## 4. Teknik Detay: C++ ve JNI (Java Native Interface) İlişkisi

Mobil cihazlarda yapay zeka modellerini yüksek performansla çalıştırmak için Dart veya Java gibi yüksek seviyeli diller doğrudan işlemci (CPU) veya grafik işlemciye (GPU) erişimde yavaş kalabilir. Projemizdeki bu darboğaz şu şekilde aşılmıştır:

*   **TFLite Native Bridge:** `tflite_flutter` kütüphanesi, Google'ın TensorFlow Lite C++ kütüphanesini kullanır.
*   **JNI Rolü:** Android tarafında, Dart kodu Java/Kotlin köprüsü üzerinden **JNI (Java Native Interface)** aracılığıyla C++ katmanına erişir.
*   **Performans:** Görüntü matrisleri C++ katmanında bellek adresleri üzerinden işlenir. Bu sayede, görüntü işleme süreçleri milisaniyeler seviyesine iner ve uygulamada donma/kasılma olmadan gerçek zamanlı tespit yapılabilir.
*   **Hardware Acceleration:** JNI üzerinden mobil cihazın NPU (Neural Processing Unit) veya GPU'su tetiklenerek modelin donanımsal hızlandırmadan yararlanması sağlanmıştır.

---

## 5. Veritabanı Yapısı

Sistemde iki katmanlı bir veri saklama yapısı vardır:

1.  **Cihaz Üzerinde (Local):** `potholes.db` (SQLite)
    *   `records` tablosu: ID, zaman, enlem, boylam, güven skoru, resim yolu, bbox koordinatları.
2.  **Sunucu Üzerinde (Remote):** `records.db` (SQLite/FastAPI)
    *   Filo yönetimi ve şehir planlama için tüm cihazlardan gelen verilerin toplandığı merkezi havuz.

---

## 6. Sonuç
RoadGuard AI; Flutter'ın esnek UI yeteneklerini, YOLOv8'in güçlü nesne tespitiyle ve C++/JNI'nın yüksek performansı ile birleştirerek, uçtan uca çalışan profesyonel bir mühendislik çözümüdür. Sunulan mimari, düşük gecikme süresi (low latency) ve yüksek doğruluk oranı ile gerçek dünya koşullarında çalışmaya uygundur.
