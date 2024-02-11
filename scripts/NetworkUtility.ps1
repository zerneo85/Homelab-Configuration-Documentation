function Get-NetworkInformation {
    param (
        [string]$WifiAdapterName = 'Wi-Fi',
        [string]$EthernetAdapterSubstring = 'Ethernet'
    )

    function Get-FormattedNetworkInfo {
        param (
            [string]$AdapterType,
            [string]$PublicIP,
            [string]$IPv4,
            [string]$MACAddress
        )
        Write-Host ""
        Write-Host "===== $AdapterType Network Information ====="
        Write-Host "Public IP    : $PublicIP"
        Write-Host "IPv4 Address : $IPv4"
        Write-Host "MAC Address  : $MACAddress"
        Write-Host ""
    }

    function Get-IPv4Address {
        param (
            [string]$InterfaceAlias
        )

        $ipv4Address = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -eq $InterfaceAlias -and $_.IPAddress -notlike '169.*' }).IPAddress
        return $ipv4Address
    }

    $publicIPWifi = (curl ifconfig.me)

    $wifiAdapter = Get-NetAdapter -Name $WifiAdapterName | Where-Object { $_.Status -eq 'Up' }

    if ($wifiAdapter) {
        $ipv4Wifi = Get-IPv4Address -InterfaceAlias $WifiAdapterName
        $macAddressWifi = $wifiAdapter.MacAddress -replace "[:-]", "-"
        Get-FormattedNetworkInfo -AdapterType "Wifi" -PublicIP $publicIPWifi -IPv4 $ipv4Wifi -MACAddress $macAddressWifi
    }

    $ethernetAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -like "*$EthernetAdapterSubstring*" }

    foreach ($ethernetAdapter in $ethernetAdapters) {
        $publicIPEthernet = (curl ifconfig.me)
        $ipv4Ethernet = Get-IPv4Address -InterfaceAlias $ethernetAdapter.InterfaceAlias
        $macAddressEthernet = $ethernetAdapter.MacAddress -replace "[:-]", "-"
        Get-FormattedNetworkInfo -AdapterType "$($ethernetAdapter.InterfaceAlias) Ethernet" -PublicIP $publicIPEthernet -IPv4 $ipv4Ethernet -MACAddress $macAddressEthernet
    }
}

# Example usage:
clear
Get-NetworkInformation

# Display menu with the specified commands
function Show-Menu {
    Write-Host "===== PowerShell Network Utility Menu ====="
    Write-Host "1. Get Network Information"
    Write-Host "2. Renew IP information"
    Write-Host "3. Ping Continuously DNS and IP Google"
    Write-Host "4. NS Lookup google"
    Write-Host "5. NS Lookup surfshark NL"
    Write-Host "6. NS Lookup surfshark GR"
    Write-Host "7. Trace Route google"
    Write-Host "8. Get Network Interfaces"
    Write-Host "9. Manage Network Adapters"
    Write-Host "0. Exit"
}

while ($true) {
    Show-Menu
    $choice = Read-Host "Enter your choice (0-18)"

    switch ($choice) {
        0 { exit }
        1 { Get-NetworkInformation }
        2 { ipconfig /renew }
        3 {
            Start-Process powershell -ArgumentList "-NoProfile -NoExit -Command ping google.com -t"
            Start-Process powershell -ArgumentList "-NoProfile -NoExit -Command ping 8.8.8.8 -t"
        }
        4 { nslookup google.com }
        5 { nslookup gr-ath.prod.surfshark.com }
        6 { nslookup nl-ams.prod.surfshark.com }
        7 { tracert google.com }
        8 { Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, MacAddress
            break
        }
        9 {
            # Get a list of available network adapters
            $networkAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }

            # Display the list of network adapters
            Write-Host "Available Network Adapters:"
            for ($i = 0; $i -lt $networkAdapters.Count; $i++) {
                $adapter = $networkAdapters[$i]
                Write-Host "$($i + 1). $($adapter.Name) - $($adapter.Description)"
            }

            # Prompt the user to select a network adapter
            $selectedAdapterIndex = Read-Host "Enter the number of the network adapter to enable/disable"

            # Validate user input
            if (-not $selectedAdapterIndex -or $selectedAdapterIndex -le 0 -or $selectedAdapterIndex -gt $networkAdapters.Count) {
                Write-Host "Invalid input. Please enter a valid number."
                return
            }

            # Get the selected network adapter
            $selectedAdapter = $networkAdapters[$selectedAdapterIndex - 1]

            # Display information about the selected network adapter
            Write-Host "Selected Network Adapter:"
            Write-Host "  Name        : $($selectedAdapter.Name)"
            Write-Host "  Description : $($selectedAdapter.Description)"
            Write-Host "  Status      : $($selectedAdapter.Status)"
            Write-Host "  MAC Address : $($selectedAdapter.MacAddress)"
            Write-Host "  Interface Index : $($selectedAdapter.InterfaceIndex)"
            Write-Host ""

            # Prompt the user to choose between enabling or disabling the selected network adapter
            $action = Read-Host "Do you want to enable (E) or disable (D) the network adapter? (E/D)"

            # Perform the selected action
            switch ($action.ToUpper()) {
                'E' {
                    Enable-NetAdapter -InterfaceIndex $selectedAdapter.InterfaceIndex
                    Write-Host "Network adapter $($selectedAdapter.Name) has been enabled."
                }
                'D' {
                    Disable-NetAdapter -Name $selectedAdapter.Name  # Use Name property to disable the adapter
                    Write-Host "Network adapter $($selectedAdapter.Name) has been disabled."
                }
                default {
                    Write-Host "Invalid choice. Please enter 'E' to enable or 'D' to disable the network adapter."
                }
            }

            # Prompt to press Enter before exiting
            Read-Host "Press Enter to exit..."
        }

        default { Write-Host "Invalid choice. Please enter a number between 0 and 18." }
    }

    Read-Host "Press Enter to continue..."
}
