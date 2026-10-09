# Third-party components

`make deps` downloads these (pinned versions, checked against SHA-256) and `make app` bundles them
into `AllInOneIME.app`. They are not stored in this repository.

| Component | Version | License | Source |
|---|---|---|---|
| librime (Rime input method engine), official macOS release build | 1.16.1 | BSD-3-Clause | https://github.com/rime/librime |
| librime-lua (plugin, in the release build) | 68f9c36 | BSD-3-Clause | https://github.com/hchunhui/librime-lua |
| librime-octagram (plugin, in the release build) | dfcc151 | BSD-3-Clause | https://github.com/lotem/librime-octagram |
| librime-predict (plugin, in the release build) | 920bd41 | BSD-3-Clause | https://github.com/rime/librime-predict |
| rime-ice 雾凇拼音 (schemas, dictionaries, Lua scripts) | 2026.06.30 | GPL-3.0 | https://github.com/iDvel/rime-ice |

The librime release build also links its own dependencies (Boost, glog, LevelDB, marisa-trie, OpenCC,
yaml-cpp, Cap'n Proto, Lua); see the librime project for their licenses.

## BSD-3-Clause notices

librime and librime-octagram: Copyright (c) 2014, RIME Developers.
librime-predict: Copyright (c) 2023, RIME Developers.
librime-lua: Copyright (c) 2021, librime-lua Developers.
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions
  and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice, this list of conditions
  and the following disclaimer in the documentation and/or other materials provided with the
  distribution.
* Neither the name of the copyright holder nor the names of its contributors may be used to endorse
  or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## rime-ice

rime-ice is licensed under the GNU General Public License v3.0 (the same text as `LICENSE` in this
repository). Its full source is included unmodified in the app bundle under
`Contents/SharedSupport/rime`, together with dictionaries prebuilt from it.
