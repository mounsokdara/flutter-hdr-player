"""Adds the CMake/JNI build and arm64-only ABI to the generated Android app module."""
import glob
import re

path = glob.glob('build_app/android/app/build.gradle*')[0]
s = open(path).read()
if path.endswith('.kts'):
    s = s.replace('defaultConfig {', 'defaultConfig {\n        ndk { abiFilters.add("arm64-v8a") }', 1)
    s = re.sub(r'(android\s*\{)', r'\1\n    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt") } }', s, 1)
else:
    s = s.replace('defaultConfig {', 'defaultConfig {\n        ndk { abiFilters "arm64-v8a" }', 1)
    s = re.sub(r'(android\s*\{)', r'\1\n    externalNativeBuild { cmake { path "src/main/cpp/CMakeLists.txt" } }', s, 1)
open(path, 'w').write(s)
print('patched', path)
print(s)
