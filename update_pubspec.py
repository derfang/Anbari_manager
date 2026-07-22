import re

with open("pubspec.yaml", "r") as f:
    content = f.read()

# Add flutter_launcher_icons to dev_dependencies if not present
if "flutter_launcher_icons:" not in content:
    content = content.replace("dev_dependencies:\n", "dev_dependencies:\n  flutter_launcher_icons: ^0.13.1\n")

# Add flutter_icons configuration if not present
if "flutter_icons:" not in content:
    content += """
flutter_icons:
  android: "ic_launcher"
  ios: true
  image_path: "assets/icon.png"
  min_sdk_android: 21 # android min sdk min:16, default 21
"""

with open("pubspec.yaml", "w") as f:
    f.write(content)
