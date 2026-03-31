import 'package:image/image.dart' as img;

void main() {
  final image = img.Image(width: 1, height: 1);
  image.setPixelRgb(0, 0, 255, 128, 64);
  final pixel = image.getPixel(0, 0);
  print('r: ${pixel.r}, g: ${pixel.g}, b: ${pixel.b}');
  print('r norm: ${pixel.r / 255.0}');
}
