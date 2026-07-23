# Third-Party Notices

PalmiAgent includes, depends on, or references the following third-party work.
Third-party components remain under their own licenses.

## Bundled and Direct Dependencies

- **ZIPFoundation** by Thomas Zoechling is vendored under `PalmiAgent/Vendor/ZIPFoundation` and is licensed under the MIT License. Its license file is included at `PalmiAgent/Vendor/ZIPFoundation/LICENSE.txt`.
- **OLEKit** by CoreOffice is linked as the `OLEKit` Swift package product at revision `398248735e690ac422b728acb79d30bd3d675554` and is used only to read OLE/CFBF containers for legacy Office indexing. Upstream: https://github.com/CoreOffice/OLEKit. OLEKit is Apache-2.0 and contains portions derived from `olefile` under its FreeBSD-style notice. The resolved package contains `LICENSE` and `LICENSE-olefile`.

`libxls` is intentionally not included or linked. SwiftText, libarchive, and XZ/liblzma are not included in this build and are therefore not represented as bundled dependencies.
- **MarkdownUI** by Guillermo Gonzalez is used as a Swift Package dependency from `https://github.com/gonzalezreal/MarkdownUI` and is licensed under the MIT License.
- **NetworkImage** by Guille Gonzalez is resolved as a Swift Package dependency and is licensed under the MIT License.
- **swift-cmark / cmark-gfm** is resolved as a Swift Package dependency and includes BSD-style and MIT-style license notices in its `COPYING` file.
- **CPython iOS runtime** is bundled under `Vendor/PythonSupport/Python.xcframework`. Its license file is included at `Vendor/PythonSupport/Python.xcframework/lib/python3.14/LICENSE.txt`.
- **Vendored Python packages** are bundled under `Vendor/PythonSupport/app_packages`. Their package metadata and license files remain in that directory. The bundle currently includes packages such as `beautifulsoup4`, `networkx`, `openpyxl`, `packaging`, `python-dateutil`, `pytz`, `six`, `sympy`, `tabulate`, `tomli`, `typing_extensions`, and `tzdata`.
- **PP-OCRv6 Tiny ONNX OCR models** by PaddlePaddle are bundled under `PalmiAgent/Resources/OCR/PP-OCRv6-tiny.bundle` and are licensed under the Apache License 2.0. The bundled files are the Tiny text detection and text recognition ONNX assets from `PaddlePaddle/PP-OCRv6_tiny_det_onnx` and `PaddlePaddle/PP-OCRv6_tiny_rec_onnx`. Local model source and checksum details are recorded in `PalmiAgent/Resources/OCR/PP-OCRv6-tiny.bundle/NOTICE.md`.

## Implementation References

- **ShipSwift** by SignerLabs informed parts of PalmiAgent's visual direction
  for the configuration UI and animated capability effects. The local
  ShipSwift reference copy includes an MIT License notice: Copyright (c) 2026
  SignerLabs.
- **cc-switch** by Jason Young informed parts of PalmiAgent's model-provider
  pairing and model discovery behavior. The local cc-switch reference copy
  includes an MIT License notice: Copyright (c) 2025 Jason Young.

Reference repositories and local research copies are intentionally excluded from the public tree by `.gitignore`.

MIT reference license text for ShipSwift and cc-switch:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Model Providers

PalmiAgent lets users configure external model providers, local model servers,
and OpenAI-compatible endpoints. Provider names and model identifiers in the UI
are used for compatibility and routing. This repository does not include model
weights, provider SDK source code, or provider services. Users are responsible
for complying with the terms of any provider they connect.
