# Lancement des commandes de l'hyperviseur : ne jamais se laisser bloquer par
# un processus petit-fils qui survit.
#
# Incident reel du 10 septembre 2026. « vmrun start <vm> gui » lance
# l'interface de VMware Workstation, puis se termine. Mais l'interface herite
# des tuyaux de sortie rediriges et les garde ouverts tant qu'elle vit : un
# StandardOutput.ReadToEnd() n'aurait rendu la main qu'a la fermeture de
# VMware. vazy restait fige alors que la VM tournait, sans aucun message.
#
# Ces tests ne demandent aucun hyperviseur : ils reproduisent la situation
# avec powershell.exe, et verifient que le motif employe par les pilotes y
# resiste.

. "$PSScriptRoot\..\Aide\Environnement.ps1"

$script:Racine = Get-RacineDepot

# Lance un processus court qui en lance un autre, plus durable, heritant des
# tuyaux de sortie. C'est la structure exacte de « vmrun start gui ».
function Start-ProcessusAvecPetitFils {
    param([int]$SecondesPetitFils = 12)
    $interne = "Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds $SecondesPetitFils' -NoNewWindow; Write-Output PRET; exit 0"
    $infos = New-Object System.Diagnostics.ProcessStartInfo
    $infos.FileName = (Get-Command powershell).Source
    $infos.Arguments = '-NoProfile -Command "' + ($interne -replace '"', '\"') + '"'
    $infos.UseShellExecute = $false
    $infos.RedirectStandardOutput = $true
    $infos.RedirectStandardError = $true
    $infos.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($infos)
}

Describe 'Commande externe - un petit-fils qui survit ne doit pas bloquer' {

    It 'rend la main des que le processus lance se termine' {
        $chrono = [System.Diagnostics.Stopwatch]::StartNew()
        $processus = Start-ProcessusAvecPetitFils -SecondesPetitFils 12
        try {
            # Le motif employe par les pilotes : lecture asynchrone, attente du
            # PROCESSUS avec un delai, puis on prend ce qui est arrive.
            $lectureSortie  = $processus.StandardOutput.ReadToEndAsync()
            $lectureErreurs = $processus.StandardError.ReadToEndAsync()
            $termine = $processus.WaitForExit(8000)
            $null = $lectureSortie.Wait(1500)
            $null = $lectureErreurs.Wait(500)

            $termine | Should Be $true
            $processus.ExitCode | Should Be 0
            # Bien plus court que les 12 s du petit-fils : c'est tout l'enjeu.
            $chrono.Elapsed.TotalSeconds | Should BeLessThan 10
        } finally {
            try { if (-not $processus.HasExited) { $processus.Kill() } } catch { }
        }
    }

    It 'confirme que le petit-fils tient bien le tuyau ouvert' {
        # Si ce test cessait de passer, c'est que la reproduction ne reproduit
        # plus rien : le test precedent ne prouverait alors plus grand-chose.
        $processus = Start-ProcessusAvecPetitFils -SecondesPetitFils 12
        try {
            $lectureSortie = $processus.StandardOutput.ReadToEndAsync()
            $processus.WaitForExit(8000) | Should Be $true
            # Le processus est fini, mais le flux ne se termine pas : le
            # petit-fils detient encore l'extremite d'ecriture.
            $lectureSortie.Wait(1500) | Should Be $false
        } finally {
            try { if (-not $processus.HasExited) { $processus.Kill() } } catch { }
        }
    }
}

Describe 'Commande externe - les pilotes emploient le bon motif' {

    $pilotes = @(
        (Join-Path $script:Racine 'lib\pilote-vmware.ps1'),
        (Join-Path $script:Racine 'lib\pilote-virtualbox.ps1')
    )

    # Le CODE seul, commentaires retires : ces tests parlent justement de
    # WaitForExit() et de ReadToEnd(), et se declencheraient sur leurs propres
    # explications. (Erreur commise en les ecrivant.)
    function Get-CodeSansCommentaires {
        param([string]$Chemin)
        $jetons = $null
        $erreurs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Chemin, [ref]$jetons, [ref]$erreurs) | Out-Null
        return (@($jetons | Where-Object { [string]$_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
    }

    foreach ($chemin in $pilotes) {

        It ("n'utilise pas de lecture bloquante dans " + (Split-Path -Leaf $chemin)) {
            $code = Get-CodeSansCommentaires -Chemin $chemin
            # ReadToEnd() synchrone : bloque tant qu'un ecrivain tient le tuyau.
            ($code -match 'ReadToEnd\s*\(\s*\)') | Should Be $false
        }

        It ("attend le processus avec un delai dans " + (Split-Path -Leaf $chemin)) {
            $code = Get-CodeSansCommentaires -Chemin $chemin
            # WaitForExit() sans argument attend AUSSI la fin de la
            # redirection, donc le petit-fils : exactement ce qu'on fuit.
            ($code -match 'WaitForExit\s*\(\s*\)') | Should Be $false
            ($code -match 'WaitForExit\s*\(\s*\$script:DelaiCommandeSec') | Should Be $true
        }
    }
}
