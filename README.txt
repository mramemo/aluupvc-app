AluUPVC Pro Trial — Test Pack v0.3

NEW in v0.3:
- Project sizes table (Code/W/H/Qty)
- Camera Scan (Arabic sketch): W×H×Qty (Qty at end). Without qty -> 1
- Results page with grouping by (Part + Length), shown in meters (2 decimals)
- Stock cutting (First-Fit Decreasing) with 6.0 / 6.5 / custom, and kerf between cuts
- Settings: Template editor (Constants + Parts + Preview), Duplicate, Import/Export rules

Build APK (recommended via GitHub Actions):
1) Create a GitHub repo and upload ALL contents of this zip.
2) Go to Actions > Build Android APK > Run workflow
3) Download artifact: app-release-apk

Or build locally (Windows):
- Run create_project.ps1 then flutter build apk --release

Notes:
- Default rules include a sample for UPVC Imappen Sliding 2 Sashes.
- You can edit templates from Settings.
