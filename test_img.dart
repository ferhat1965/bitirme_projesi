import 'package:image/image.dart' as img;
import 'dart:io';

void main() async {
  final image = img.Image(width: 1, height: 1);
  image.setPixelRgb(0, 0, 255, 128, 64);
  final pixel = image.getPixel(0, 0);
  print('R: $({pixel.r} G: $({pixel.g} B: $({pixel.b}');
}
