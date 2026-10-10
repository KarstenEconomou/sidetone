#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/app-bundle.sh
package_app SidetoneProbe build/SidetoneProbe.app com.sidetone.probe 'Sidetone Probe'
exec build/SidetoneProbe.app/Contents/MacOS/SidetoneProbe "$@"
