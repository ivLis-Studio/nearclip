#!/bin/zsh
# Runs a PowerShell snippet in the logged-in user's session of the "Windows 11" Parallels VM.
#   tools/acceptance/guest.sh 'Get-Clipboard'
script="\$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $1"
enc=$(printf '%s' "$script" | iconv -t UTF-16LE | base64)
prlctl exec 'Windows 11' --current-user powershell -NoProfile -NonInteractive -EncodedCommand "$enc" 2>&1 | sed -e '/^#< CLIXML/d' -e '/^<Objs/d'

