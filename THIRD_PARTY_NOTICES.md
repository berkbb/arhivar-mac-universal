# Third-Party Notices

Arhivar's own source code is licensed under the MIT License (see `LICENSE`).
Arhivar bundles and runs the following third-party software. Its license
terms are **not** changed by Arhivar's license.

## 7-Zip (7zz console program)

- Author: Igor Pavlov — https://www.7-zip.org
- Source code: https://www.7-zip.org/download.html and https://github.com/ip7z/7zip
- License: GNU LGPL v2.1 or later, plus BSD 3-clause / BSD 2-clause for some
  code, and the **unRAR license restriction** for the RAR decompression code.
  The full text ships with the app as `7-Zip-License.txt` (and next to an
  updated engine as `License.txt`).

Arhivar does not modify, link against, or contain 7-Zip source code. It
launches the unmodified `7zz` executable as a separate process. Users can
replace that executable at any time (Settings › Advanced, or the
`update-7zip.sh` updater), as the LGPL requires.

unRAR license restriction (summary): the RAR decompression code cannot be used
to re-create the RAR compression algorithm, which is proprietary. For this
reason Arhivar can extract RAR archives but cannot create them.

RAR is a registered trademark of Alexander Roshal. 7-Zip is a trademark of
Igor Pavlov. Arhivar is an independent project and is not affiliated with or
endorsed by either.
