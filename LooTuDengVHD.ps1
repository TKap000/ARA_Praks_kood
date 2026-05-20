####
# Küsi admini õigust
####
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { Start-Process powershell.exe "-NoProfile -ExecutionPolicy remotesigned -File `"$PSCommandPath`"" -Verb RunAs; exit }


# Kas loon VHD faili?
$ans = Read-Host "Kas loon VHD faili? [J/E/Y/N]"
#while("y","n","Y","N","j","e","J","E" -notcontains $ans)
while ($ans -notmatch '^[YyJjNnEe]$')
{
	$ans = Read-Host "J/E/Y/N"
}
if ($ans -eq "Y" -or $ans -eq "y" -or $ans -eq "J" -or $ans -eq "j")
{
    # Ühendan serveriga
    net use s: /delete /y 2>$null
    # Tuleb ette anda SMB kausta kasutajanimi ja parool, et sinna ligi pääseda
    net use s: \\xxx.xxx.xxx.xxx\share /user:xxxxx yyyyy

    # Loon VHD kausta
    New-Item -ItemType Directory -Path C:\VHD -Force
    # Loon original kausta
    New-Item -ItemType Directory -Path C:\VHD\Original -Force
    Set-Location C:\VHD

    # Loon VHD faili 
    diskpart /s S:\TuDeng\diskpart_VHD.txt

    # Paigaldan Windows 11 VHD failile
    dism /apply-image /imagefile:S:\win11\sources\install.wim /index:6 /applydir:V:\
    #dism /image:V:\ /add-driver /driver:S:\config\drivers /recurse
    dism /image:V:\ /add-driver /driver:S:\config\drivers\Dell5400 /recurse


    # Veendun, et Panther kaust on V: kettal (VHD sees) olemas
    $pantherPath = "V:\Windows\Panther"
    if (!(Test-Path $pantherPath)) {
        New-Item -ItemType Directory -Path $pantherPath -Force
    }

    # Kopeerin fail võrgukettalt kohaliku VHD Panther kausta nimega unattend.xml
    # NB! Panther kaustas EI TOHI olla nimi "autounattend.xml"
    Copy-Item -Path "S:\TuDeng\unattend.xml" -Destination "$pantherPath\unattend.xml" -Force

    # Igaks juhuks  ütlen DISM-ile, kus see asub, unattend.xml 
    # aga kopeerimisest peaks tavaliselt piisama
    dism /image:V:\ /apply-unattend:"$pantherPath\unattend.xml"

    # Lisan lisaskriptid
    $ARAScriptPath = "V:\ARAScript"
    if (!(Test-Path $ARAScriptPath)) {
        New-Item -ItemType Directory -Path $ARAScriptPath -Force
    }

    Copy-Item -Path "S:\TuDeng\Lisaskriptid\ARABGInfo" -Destination "$ARAScriptPath" -Recurse -Force
    Copy-Item -Path "S:\TuDeng\Lisaskriptid\VHDStartupskript" -Destination "$ARAScriptPath" -Recurse -Force

    # Muudan HDD installi nimi
    bcdedit /set `{current`} description "Windows 11 HDD"

    # Loon uus VHD boodi BCD kirje
    $temp = bcdedit /copy `{default`} /d "Windows 11 Praktikum"
    $newId = (Select-String -InputObject $temp -Pattern "({.*})").Matches.Value
    bcdedit /set $newId device vhd=[C:]\VHD\Win11.vhdx
    bcdedit /set $newId osdevice vhd=[C:]\VHD\Win11.vhdx

}