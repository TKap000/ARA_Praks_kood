# =========================================================
# Klassiruumi taastamine GUI kasuajaliidesega
# =========================================================

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { 
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy remotesigned -File `"$PSCommandPath`"" -Verb RunAs; exit 
}

Add-Type -AssemblyName PresentationFramework

# ---------- Muutujad ----------
$SourcePath = "C:\VHD\original\win11.vhdx"
$DestPath   = "C:\VHD\win11.vhdx"
$BootName   = "Windows 11 Praktikum"
$TudengPassword = "xxxxxxx"
$OppejoudPassword = "xxxxxxx"

# VHD faili suurus
if (Test-Path $SourcePath) {
    $Global:TotalVhdSize = (Get-Item $SourcePath).Length
} else {
    $Global:TotalVhdSize = 1GB # Fallback väärtus, kui faili pole
}

# ---------- Kasutja andmed ----------

# --- Tudeng  ---
$username_1 = "Tu Deng"
$password_1 = ConvertTo-SecureString $TudengPassword -AsPlainText -Force
$StudentCred = New-Object System.Management.Automation.PSCredential($username_1, $password_1)

# --- Oppejoud  ---
$username_2 = "Oppejoud"
$password_2 = ConvertTo-SecureString $OppejoudPassword -AsPlainText -Force

$TeacherCred = New-Object System.Management.Automation.PSCredential($username_2, $password_2)


# ---------- Arvuti nimed ----------
$ArvutiNimed_Wifi = "ARA-01","ARA-05","ARA-09"
$ArvutiNimed_PS   = "ARA-02","ARA-03","ARA-04","ARA-10","ARA-11","ARA-12"
$ArvutiNimed_CL   = "ARA-06","ARA-07","ARA-08"
$ArvutiNimed_HDD  = "ARA-HDD1","ARA-HDD2","ARA-HDD3"

$ArvutiNimed = $ArvutiNimed_Wifi + $ArvutiNimed_PS + $ArvutiNimed_CL + $ArvutiNimed_HDD
#$ArvutiNimed = "ARA-01", "ARA-02"

# ---------- XAML faili laadimine ----------
$xamlPath = Join-Path $PSScriptRoot "MainWindow.xaml"
[xml]$xaml = Get-Content $xamlPath
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

$ComputerList = $Window.FindName("ComputerList")
$ScanBtn      = $Window.FindName("ScanBtn")
$RestoreVHDBtn   = $Window.FindName("RestoreVHDBtn")
$RestartToAdminBtn   = $Window.FindName("RestartToAdminBtn")
$ExitBtn      = $Window.FindName("ExitBtn")
$SelectAllChk = $Window.FindName("SelectAllChk")

$script:teacherSession = $null

# ---------- Arvutite skaneerimise funktsioon ----------

function Scan-Computers {

    $ComputerList.Items.Clear()
    Get-PSSession | Remove-PSSession -ErrorAction SilentlyContinue

    $sessopt = New-PSSessionOption `
        -CancelTimeout 10000 `
        -OperationTimeout 300000 `
        -OpenTimeout 5000

    $script:Sessions = @()

    foreach ($arvuti in ($ArvutiNimed | Sort-Object)) {

        $session = $null
        $usedCred = "None"

        Write-Host "Scanning $arvuti..." -ForegroundColor Cyan

        # Esmalt proovin Tudengit, kui see ebaonnestub, proovin Oppejoudu
        try {
            $session = New-PSSession `
                -ComputerName $arvuti `
                -Credential $StudentCred `
                -SessionOption $sessopt `
                -ErrorAction Stop

            $usedCred = "Student"
            #Write-Host "Trying to connect $arvuti using Student credentials." -ForegroundColor Green
        }
        catch {
            
            try {
                if ($TeacherCred) {
                    $session = New-PSSession `
                        -ComputerName $arvuti `
                        -Credential $TeacherCred `
                        -SessionOption $sessopt `
                        -ErrorAction Stop

                    $usedCred = "Teacher"
                    #Write-Host "Trying to connect $arvuti using Teacher credentials." -ForegroundColor yellow
                }
            }
            catch {
                $session = $null
            }
        }

        $isOnline = $null -ne $session

        if ($isOnline) {
            $script:Sessions += $session
        }

        $ComputerList.Items.Add([pscustomobject]@{
            Status   = if ($isOnline) { "OK" } else { "FAIL" }
            Name     = $arvuti
            Role     = if ($isOnline) { $usedCred } else { "None" }
            Action   = if ($isOnline) { "Ready ($usedCred)" } else { "Offline/Auth Fail" }
            Progress = 0
            IsSelected = $false
        })
    }

    Write-Host "Scan complete. Sessions established: $($script:Sessions.Count)" -ForegroundColor Green
    return $script:Sessions
}

# ---------- Timer GUI värskendamine ----------

$Timer = New-Object System.Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromSeconds(5)

$Timer.Add_Tick({

    # Kogume koik objektid, et neid vajadusel asendada
    $items = @()
    foreach ($item in $ComputerList.Items) { $items += $item }

    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        $jobName = "VHDJob_$($item.Name)"
        $job = Get-Job -Name $jobName -ErrorAction SilentlyContinue

        $changed = $false

        if ($job -and $job.State -eq "Running") {
            $networkPath = "\\$($item.Name)\C$\VHD\win11.vhdx"
            if (Test-Path $networkPath -PathType Leaf) {
                try {
                    $remoteLog = "\\$($item.Name)\C$\VHD\copy_log.txt"
                    if (Test-Path $remoteLog) {
                        $logContent = Get-Content $remoteLog -Tail 1 -ErrorAction SilentlyContinue
                        Write-Host "Log content for $($item.Name): $logContent" -ForegroundColor Cyan
                        $matches = [regex]::Matches($logContent, '(\d{1,3}(?:[\.,]\d{1,2})?)%?')
                        if ($matches.Count -gt 0) {
                            $lastPercentStr = $matches[$matches.Count-1].Groups[1].Value.Replace(',', '.')
                            $percent = [math]::Floor([double]$lastPercentStr)
                            Write-Host "Parsed percentage for $($item.Name): $percent%" -ForegroundColor Green
                            $item.Progress = $percent
                            $item.Action = "Copying... $percent%"
                            $changed = $true
                        } else {
                            $item.Action = "Copy log unreadable"
                            $changed = $true
                        }
                    } else {
                        $item.Action = "Starting copy..."
                        $changed = $true
                    }
                } catch {
                    $item.Action = "Log Read Error"
                    $changed = $true
                }
            } else {
                $item.Action = "Initializing..."
                $changed = $true
            }
        } elseif ($job -and ($job.State -eq "Completed" -or $job.State -eq "Failed")) {
            $item.Progress = 100
            $item.Status   = "DONE"
            $item.Action   = "Rebooting..."
            $changed = $true
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }

        if ($changed) {
            # Eemalda ja lisa uuesti, et binding käivituks
            $ComputerList.Items.Remove($item)
            $ComputerList.Items.Insert($i, $item)
        }
    }
    $ComputerList.Items.Refresh()
})


$Timer.Start()


# ---------- Nupud ----------

# Scan Button - Skaneerib arvuteid ja loob PS sessioonid
$ScanBtn.Add_Click({ $script:teacherSession = Scan-Computers })


# Restore VHD Button - Kopeerib VHD faili 
$RestoreVHDBtn.Add_Click({
    if (-not $script:teacherSession) { 
        [System.Windows.MessageBox]::Show("Please scan computers first.")
        return 
    }

    if ($SelectAllChk.IsChecked) {
        # Taasta koik, mille Status = OK

        $targets = $ComputerList.Items |
            Where-Object { $_.Status -eq "OK" -and $_.Role -eq "Teacher" }
        
        if (-not $targets) {
            [System.Windows.MessageBox]::Show("Only Teacher machines can copy VHD.")
            return
        }
    }
    else {
        # Taasta ainult valitud (voib olla 1 voi mitu)
        if (-not $ComputerList.SelectedItems.Count) {
            [System.Windows.MessageBox]::Show("Select one or more computers or check 'Restart ALL'.")
            return
        }

        $targets = $ComputerList.SelectedItems | 
            Where-Object { $_.Status -eq "OK" }#-and $_.IsSelected -eq $True }

        if (-not $targets) {
            [System.Windows.MessageBox]::Show("Selected computers are OFFLINE.")
            return
        }
    }

    foreach ($item in $targets) {
        $item.Status = "BUSY"
        $item.Action = "Starting..."
        $item.Progress = 0

        $targetSess = $script:teacherSession | Where-Object ComputerName -eq $item.Name
        $jobName = "VHDJob_$($item.Name)"

        # Start background task
        Invoke-Command -Session $targetSess -AsJob -JobName $jobName -ScriptBlock {

            $ErrorActionPreference = "Stop"

            $source      = "C:\VHD\original"
            $dest        = "C:\VHD"
            $fileName    = "win11.vhdx"
            $fullDestPath = Join-Path $dest $fileName
            $bootN       = "Windows 11 Praktikum"
            $logPath    = "C:\VHD\copy_log.txt"

            # Kustutan vana VHD faili ja vana logi, kui need on olemas
            if (Test-Path $fullDestPath) {Remove-Item $fullDestPath -Force -ErrorAction SilentlyContinue}
            if (Test-Path $logPath) { Remove-Item $logPath -Force -ErrorAction SilentlyContinue }

            # Teostan kopeerimise Robocopy abil
            Start-Process robocopy -ArgumentList "$source $dest $fileName /NJH /NJS /R:2 /W:2 /LOG:$logPath" -Wait

            # Robocopy vea kontroll
            if ($LASTEXITCODE -ge 8) {
                throw "Robocopy failed with exit code $LASTEXITCODE"
            }

            # Boot järjestuse muutmine
            $bcd = bcdedit /v
            $id = $bcd | Select-String $bootN -Context 5,0 | ForEach-Object {
                if ($_.Context.PreContext -join "`n" -match "(?i)(?<id>\{[a-z0-9-]{36}\})") {
                    $Matches['id']
                }
            } | Where-Object { $_ -ne "{current}" } | Select-Object -First 1

            if ($id) {
                bcdedit /bootsequence $id

                # HP BIOS seaded
                $bios = Get-CimInstance -Namespace "root\hp\instrumentedbios" `
                                        -ClassName hp_biossettinginterface `
                                        -ErrorAction SilentlyContinue

                if ($bios) {
                    Invoke-CimMethod -InputObject $bios `
                                    -MethodName SetBIOSSetting `
                                    -Arguments @{Name="Virtualization Technology (VTx)"; Value="Disable"} `
                                    -ErrorAction SilentlyContinue
                }

                Start-Sleep 3
                Restart-Computer -Force
            }
        }

    }

})


# Restart Admin Button - Taaskäivitab Administraatori režiimi
$RestartToAdminBtn.Add_Click({

    if (-not $script:teacherSession) {
        [System.Windows.MessageBox]::Show("Please scan computers first.")
        return
    }

    if ($SelectAllChk.IsChecked) {

        $targets = $ComputerList.Items |
            Where-Object { $_.Status -eq "OK" -and $_.Role -eq "Student" }

        if (-not $targets) {
            [System.Windows.MessageBox]::Show("Only Student machines can reboot to Admin.")
            return
        }

    }
    else {

        if (-not $ComputerList.SelectedItems.Count) {
            [System.Windows.MessageBox]::Show("Select one or more computers or check 'Restart ALL'.")
            return
        }

        $targets = $ComputerList.SelectedItems |
            Where-Object { $_.Status -eq "OK" }#-and $_.IsSelected -eq $True }

        if (-not $targets) {
            [System.Windows.MessageBox]::Show("Selected computers are OFFLINE.")
            return
        }
    }

    # ---------- Arvutid Oppejoudu ----------
    foreach ($item in $targets) {

        $session = $script:teacherSession |
            Where-Object ComputerName -eq $item.Name

        if (-not $session) { continue }

        $item.Action = "Rebooting To Admin..."

        Invoke-Command -Session $session {

            $bootName = "Windows 11 HDD"
            $bcdOutput = bcdedit /v
            $targetBlock = $bcdOutput | Select-String $bootName -Context 5,1

            if ($targetBlock) {
                $bootid = [regex]::Match(
                    $targetBlock.Context.PreContext,
                    '\{[a-z0-9-]{36}\}'
                ).Value

                if ($bootid -and $bootid -ne "{current}") {
                    bcdedit /bootsequence $bootid
                    Restart-Computer -Force
                }
            }
        }
    }

    $ComputerList.Items.Refresh()
})


# Exit Button - Peatab timeri, sulgeb sessioonid ja sulgeb akna
$ExitBtn.Add_Click({
    $Timer.Stop()
    Get-Job | Remove-Job -Force
    $Window.Close()
})


$Window.ShowDialog() | Out-Null