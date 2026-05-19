# Python Package Bundle

This project ships a curated pure-Python package bundle for the embedded iOS CPython runtime.

Goals:
- Keep the Python runtime resource budget within `250MB`.
- Only ship packages that work without compiling native extensions for iOS.
- Make the available third-party package surface explicit in tool descriptions and prompts.

Current budget notes:
- Embedded `Python.xcframework` in the repo: about `124MB`
- Curated third-party packages under `Vendor/PythonSupport/app_packages`: about `46MB`
- Build-time stdlib pruning saves about `38MB` by removing `test`, `idlelib`, `tkinter`, `turtledemo`, and `ensurepip`

Pinned vendored packages:
- `beautifulsoup4==4.14.3`
- `et_xmlfile==2.0.0`
- `mpmath==1.3.0`
- `networkx==3.2.1`
- `openpyxl==3.1.5`
- `packaging==26.1`
- `python-dateutil==2.9.0.post0`
- `pytz==2026.1.post1`
- `six==1.17.0`
- `soupsieve==2.8.3`
- `sympy==1.14.0`
- `tabulate==0.9.0`
- `tomli==2.4.1`
- `tomli-w==1.2.0`
- `typing_extensions==4.15.0`
- `tzdata==2026.1`

Supported top-level imports:
- `bs4`
- `soupsieve`
- `dateutil`
- `pytz`
- `tzdata`
- `openpyxl`
- `et_xmlfile`
- `tabulate`
- `networkx`
- `sympy`
- `mpmath`
- `tomli`
- `tomli_w`
- `packaging`
- `six`
- `typing_extensions`

Explicitly unsupported examples:
- `numpy`
- `pandas`
- `matplotlib`
- `Pillow`
- `requests`
- `pydantic`
- `scipy`

To refresh the vendored bundle, run:

```sh
./scripts/vendor-python-packages.sh
```
