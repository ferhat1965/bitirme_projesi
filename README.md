# 🚧 Yapay Zeka Tabanlı Yol Çukur ve Kasis Tespit Sistemi

Bu proje, araç kamerası kullanarak **yoldaki çukurları (pothole)** ve **kasisleri (speed bump)** gerçek zamanlı olarak tespit eden bir yapay zeka sistemidir.
Model, **YOLOv8** algoritması ile eğitilmiş olup mobil cihazlarda çalışabilecek şekilde optimize edilmiştir.

---

## 🎯 Projenin Amacı

* Sürüş güvenliğini artırmak
* Sürücüyü önceden uyarmak
* Yol bozukluklarını kayıt altına almak
* Belediyeler için veri sağlamak

---

## 🧠 Kullanılan Teknolojiler

* Python
* YOLOv8 (Ultralytics)
* OpenCV
* Google Colab
* Flutter (Mobil uygulama)
* TensorFlow Lite (Mobil optimizasyon)

---

## ⚙️ Sistem Nasıl Çalışır?

1. Araç kamerasından görüntü alınır
2. Görüntü YOLOv8 modeli ile analiz edilir
3. Çukur veya kasis tespit edilirse:

   * Ekranda gösterilir
   * Sürücü uyarılır
4. GPS ile konum kaydedilir
5. Veriler harita üzerinde işaretlenir

---

## 📊 Model Performansı

* mAP (Mean Average Precision): ~%85+
* Gerçek zamanlı tespit (Real-time detection)
* Düşük gecikme süresi


---

## 📱 Mobil Uygulama Özellikleri

* 🎥 Canlı kamera ile tespit
* 🗺️ Harita üzerinde çukur/kasis gösterimi
* 📍 GPS ile konum kaydı
* 📂 Kayıtlı tespitleri görüntüleme
* 👤 Kullanıcı profili

---



## 👨‍💻 Geliştirici

Ferhat Rammok

---

## ⭐ Not

Bu proje, bitirme projesi kapsamında geliştirilmiş olup yapay zeka destekli bir sistem ile yol güvenliğini artırmayı amaçlamaktadır. Geliştirilen sistem, hem mobil hem de masaüstü (desktop) platformlarda çalışacak şekilde tasarlanmıştır ve gerçek zamanlı analiz yapabilmektedir.
