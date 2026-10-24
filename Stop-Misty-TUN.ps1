#requires -Version 5.1
# Compatibility name for this AutoBridge installation only.
# This never searches for or stops an unrelated legacy Misty TUN.
[CmdletBinding()]
param([switch]$Emergency)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Stop-Bridge.ps1') -Emergency:$Emergency
