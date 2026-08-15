# Third-party licenses

DOKA itself is licensed under [GPL-3.0](LICENSE). The components listed below are **not**
covered by that license — they are used under their own terms. All of them are permissive
(MIT or Apache-2.0) and one-way compatible with GPL-3.0, so distributing DOKA under the GPL
carries no conflicting obligations.

Versions are taken from `DOKA-app/Package.resolved`.

## Swift packages

| Component | Version | License | Source |
|---|---|---|---|
| KeyboardShortcuts | 2.4.0 | MIT | https://github.com/sindresorhus/KeyboardShortcuts |
| WhisperKit (argmax-oss-swift) | 0.18.0 | MIT | https://github.com/argmaxinc/argmax-oss-swift |
| FluidAudio | 0.15.5 | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| swift-asn1 | 1.7.1 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-collections | 1.6.0 | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-crypto | 4.5.1 | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-jinja | 2.4.2 | Apache-2.0 | https://github.com/huggingface/swift-jinja |
| swift-transformers | 1.1.9 | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| yyjson | 0.12.0 | MIT | https://github.com/ibireme/yyjson |

FluidAudio bundles its own third-party components (`fastcluster`, `vbx`); their licenses
ship with the package in `ThirdPartyLicenses/`.

## Speech models

Models are downloaded by the user at runtime and are not part of this repository or of the
application bundle.

| Model | License | Source |
|---|---|---|
| Whisper large-v3-turbo (OpenAI) | MIT | https://huggingface.co/openai/whisper-large-v3-turbo |
| Parakeet TDT 0.6B v3 (NVIDIA) | CC-BY-4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |

**Attribution required by CC-BY-4.0:** *Parakeet TDT 0.6B v3* by NVIDIA, used under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## NOTICE files (Apache-2.0 §4(d))

Two dependencies ship a `NOTICE` file whose contents must travel with any distribution that
includes them.

### swift-crypto

```
                            The SwiftCrypto Project
                            =======================

Please visit the SwiftCrypto web site for more information:

  * https://github.com/apple/swift-crypto

Copyright 2019 The SwiftCrypto Project

The SwiftCrypto Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.
```

### swift-asn1

```
                            The SwiftASN1 Project
                            =====================

Please visit the SwiftASN1 web site for more information:

  * https://github.com/apple/swift-asn1

Copyright 2022 The SwiftASN1 Project

The SwiftASN1 Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

---

This product contains derivations of various scripts from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio

---

This product contains derivations of various scripts from Swift OpenAPI Generator.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-openapi-generator
```
