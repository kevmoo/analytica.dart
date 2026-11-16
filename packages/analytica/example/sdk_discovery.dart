import 'package:analytica/sdk_discovery.dart';

void main() {
  final sdkPath = findSdkPath();
  final dartExec = findDartExecutable(sdkPath: sdkPath);
  print('Dart SDK: $sdkPath');
  print('Dart Binary: $dartExec');
}
