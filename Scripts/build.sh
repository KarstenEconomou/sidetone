#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/app-bundle.sh
bash Scripts/icon.sh
package_app Sidetone dist/Sidetone.app com.sidetone.app Sidetone AppIcon.icns
