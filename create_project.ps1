param(
  [string]$ProjectName = "aluupvc_trial",
  [string]$Package = "com.example.aluupvc"
)

Write-Host "== Creating Flutter project: $ProjectName ==" -ForegroundColor Green
flutter create $ProjectName --org $Package

Write-Host "== Copying app files ==" -ForegroundColor Green
Copy-Item -Force -Recurse ".\app_files\assets" ".\$ProjectName\assets"
Copy-Item -Force ".\app_files\lib\main.dart" ".\$ProjectName\lib\main.dart"
Copy-Item -Force ".\app_files\pubspec.yaml" ".\$ProjectName\pubspec.yaml"

Write-Host "== Getting packages ==" -ForegroundColor Green
Push-Location $ProjectName
flutter pub get
Pop-Location

Write-Host "Done. Next: cd $ProjectName ; flutter run  (or) flutter build apk --release" -ForegroundColor Cyan
