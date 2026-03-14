# BarelyMetal - Power Management Fix
# Fixes VMAware POWER_CAPABILITIES detection
# Run as Administrator, then restart

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$powerKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Power"

# Enable hibernate (sets HiberFilePresent = true)
powercfg /hibernate on
Set-ItemProperty -Path $powerKey -Name "HibernateEnabled" -Value 1 -Type DWord

# Enable Modern Standby (S0 Low Power Idle) via PlatformAoAcOverride.
# This forces Windows to report AoAc=true in SystemPowerCapabilities,
# satisfying the (S0 || S3) condition in VM detection checks.
Set-ItemProperty -Path $powerKey -Name "PlatformAoAcOverride" -Value 1 -Type DWord
Set-ItemProperty -Path $powerKey -Name "CsEnabled" -Value 1 -Type DWord

Write-Host "Power management fix applied. Please restart."
