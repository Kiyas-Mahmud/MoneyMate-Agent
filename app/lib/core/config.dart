/// Backend address. The Android emulator reaches the host machine at 10.0.2.2.
/// Override for a real phone: flutter run --dart-define=API_BASE=http://192.168.x.x:8000/api
const String apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:8000/api');

/// Address other people use to check a receipt (landlord, university, visa office). In a deployment this is
/// the public server, not the emulator-only 10.0.2.2 address.
const String publicBase = String.fromEnvironment('PUBLIC_BASE', defaultValue: 'http://10.0.2.2:8000');
