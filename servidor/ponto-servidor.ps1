# ===== PONTO PAUVAN - programa do servidor =====
# Lê as batidas do relógio iDFace (rede do mercado) a cada 30 segundos e manda para o APPS PAUVAN (planilha PONTO PAUVAN).
# Também acerta a hora do relógio pela hora do computador todo dia às 03:00
# e troca a fala do relógio conforme o horário (bom dia / bom almoço / boa tarde / bom descanso), puxando os áudios da nuvem.
# Também tira a foto da câmera do relógio quando o Celio pede no app (gestão › Hoje)
# e se atualiza sozinho: a cada 1 hora confere no GitHub (meu-pauvan/servidor) se tem versão nova.
# Configuração: arquivo ponto-config.txt na mesma pasta.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$pasta = Split-Path -Parent $MyInvocation.MyCommand.Path
$arqCfg = Join-Path $pasta 'ponto-config.txt'
$arqUlt = Join-Path $pasta 'ultimo-id.txt'
$arqLog = Join-Path $pasta 'ponto-log.txt'

function Log($t) {
  $l = (Get-Date -Format 'dd/MM/yyyy HH:mm:ss') + '  ' + $t
  Add-Content -Path $arqLog -Value $l -Encoding UTF8
  if ((Get-Item $arqLog).Length -gt 2MB) { Move-Item $arqLog ($arqLog + '.old') -Force }
}
function LerCfg {
  $c = @{}
  Get-Content $arqCfg -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$') { $c[$matches[1]] = $matches[2].Trim() }
  }
  return $c
}
$cfg = LerCfg
$relogio = 'http://' + $cfg.RELOGIO_IP
$sessao = $null

function Relogio($caminho, $corpo) {
  if (-not $script:sessao) {
    $r = Invoke-RestMethod -Uri ($relogio + '/login.fcgi') -Method Post -ContentType 'application/json' -Body (@{ login = $cfg.RELOGIO_USUARIO; password = $cfg.RELOGIO_SENHA } | ConvertTo-Json) -TimeoutSec 15
    $script:sessao = $r.session
  }
  try {
    return Invoke-RestMethod -Uri ($relogio + '/' + $caminho + '?session=' + $script:sessao) -Method Post -ContentType 'application/json' -Body ($corpo | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 20
  } catch {
    $script:sessao = $null; throw
  }
}
function RelogioAudio($nome, [byte[]]$bytes) {
  if (-not $script:sessao) { $null = Relogio 'system_information.fcgi' @{} }
  $u = $relogio + '/set_audio_access_message.fcgi?event=authorized&current=1&total=1&session=' + $script:sessao
  $null = Invoke-RestMethod -Uri $u -Method Post -ContentType 'application/octet-stream' -Body $bytes -TimeoutSec 30
  $null = Relogio 'set_configuration.fcgi' @{ buzzer = @{ audio_message_authorized = 'custom' } }
}
function Nuvem($dados) {
  $dados.chave = $cfg.CHAVE
  $json = $dados | ConvertTo-Json -Depth 6 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  return Invoke-RestMethod -Uri $cfg.URL_APP -Method Post -ContentType 'text/plain; charset=utf-8' -Body $bytes -TimeoutSec 60
}
function HoraDoRelogio {
  $i = Relogio 'system_information.fcgi' @{}
  return ([DateTime]'1970-01-01').AddSeconds($i.time)   # o relógio guarda a hora local como se fosse UTC
}

$ultimo = 0
if (Test-Path $arqUlt) { $ultimo = [int64](Get-Content $arqUlt -Raw) }
Log ('Programa iniciado. Último registro lido: ' + $ultimo)
$ultimoAviso = [DateTime]::MinValue
$acertouHoje = ''
$audioVersao = ''
$audioConferido = [DateTime]::MinValue
$atualConferido = [DateTime]::MinValue
$urlPrograma = 'https://raw.githubusercontent.com/mercadopauvan/meu-pauvan/main/servidor/ponto-servidor.ps1'

while ($true) {
  try {
    # 1) batidas novas (evento 7 = acesso liberado = ponto registrado)
    $r = Relogio 'load_objects.fcgi' @{ object = 'access_logs'; where = @{ access_logs = @{ id = @{ '>' = $ultimo } } } }
    $novos = @($r.access_logs)
    if ($novos.Count -gt 0) {
      $bat = @()
      $maior = $ultimo
      foreach ($a in $novos) {
        if ([int64]$a.id -gt $maior) { $maior = [int64]$a.id }
        if ($a.event -eq 7 -and $a.user_id -gt 0) {
          $dt = ([DateTime]'1970-01-01').AddSeconds($a.time)
          $bat += @{ codigo = [string]$a.user_id; dataHora = $dt.ToString('yyyy-MM-ddTHH:mm:ss') }
        }
      }
      if ($bat.Count -gt 0) {
        $resp = Nuvem @{ acao = 'pontoReceber'; batidas = $bat; horaRelogio = (Get-Date -Format 'dd/MM HH:mm') }
        if (-not $resp.ok) { throw ('a nuvem recusou: ' + $resp.erro) }
        Log ('Enviadas ' + $bat.Count + ' batida(s); novas na planilha: ' + $resp.novas)
      }
      $ultimo = $maior
      Set-Content -Path $arqUlt -Value $ultimo
      $ultimoAviso = Get-Date
    }
    # 2) sinal de vida a cada 15 min (aparece na gestão do ponto)
    if (((Get-Date) - $ultimoAviso).TotalMinutes -ge 15) {
      $h = HoraDoRelogio
      $null = Nuvem @{ acao = 'pontoStatusRelogio'; horaRelogio = $h.ToString('dd/MM HH:mm:ss') }
      $ultimoAviso = Get-Date
    }
    # 3) acerta a hora do relógio pela hora deste computador, uma vez por dia (03:00)
    $agora = Get-Date
    if ($agora.Hour -eq 3 -and $acertouHoje -ne $agora.ToString('yyyyMMdd')) {
      $null = Relogio 'set_system_time.fcgi' @{ day = $agora.Day; month = $agora.Month; year = $agora.Year; hour = $agora.Hour; minute = $agora.Minute; second = $agora.Second }
      $acertouHoje = $agora.ToString('yyyyMMdd')
      Log 'Hora do relógio acertada pela hora do computador.'
    }
  } catch {
    Log ('ERRO: ' + $_.Exception.Message)
    Start-Sleep -Seconds 30
  }
  # 4) fala do relógio conforme o horário (confere a cada 1 minuto)
  if (((Get-Date) - $audioConferido).TotalSeconds -ge 60) {
    $audioConferido = Get-Date
    try {
      $a = Nuvem @{ acao = 'pontoAudioAgora' }
      if ($a.ok -and $a.versao -and $a.versao -ne $audioVersao) {
        $arq = Nuvem @{ acao = 'pontoAudioArquivo'; nome = $a.nome }
        if (-not $arq.ok) { throw ('áudio: ' + $arq.erro) }
        RelogioAudio $a.nome ([Convert]::FromBase64String($arq.b64))
        $audioVersao = $a.versao
        Log ('Fala do relógio trocada para: ' + $a.nome)
      }
    } catch {
      $script:sessao = $null
      Log ('ERRO no áudio: ' + $_.Exception.Message)
    }
  }
  # 5) foto do relógio pedida pelo app (gestão › Hoje › Ver o relógio agora)
  try {
    $fp = Nuvem @{ acao = 'pontoFotoPendente' }
    if ($fp.ok -and $fp.pedido) {
      if (-not $script:sessao) { $null = Relogio 'system_information.fcgi' @{} }
      $wc = New-Object Net.WebClient
      $wc.Headers['Content-Type'] = 'application/json'
      $png = $wc.UploadData(($relogio + '/save_screenshot.fcgi?session=' + $script:sessao), 'POST', [Text.Encoding]::UTF8.GetBytes('{"frame_type":"camera","camera":"rgb"}'))
      $foto = $png; $mime = 'image/png'
      try {
        Add-Type -AssemblyName System.Drawing
        $ms = New-Object IO.MemoryStream(, $png)
        $img = [Drawing.Image]::FromStream($ms)
        $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        $ep = New-Object Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter([Drawing.Imaging.Encoder]::Quality, [long]75)
        $out = New-Object IO.MemoryStream
        $img.Save($out, $enc, $ep); $img.Dispose()
        $foto = $out.ToArray(); $mime = 'image/jpeg'
      } catch { }
      $rf = Nuvem @{ acao = 'pontoFotoSalvar'; pedido = $fp.pedido; mime = $mime; b64 = [Convert]::ToBase64String($foto) }
      Log ('Foto do relógio enviada para o app (' + $foto.Length + ' bytes)')
    }
  } catch {
    $script:sessao = $null
    Log ('ERRO na foto do relógio: ' + $_.Exception.Message)
  }
  # 6) atualização automática: a cada 1 hora confere se tem versão nova deste programa no GitHub e se troca sozinho
  if (((Get-Date) - $atualConferido).TotalMinutes -ge 60) {
    $atualConferido = Get-Date
    try {
      $wc2 = New-Object Net.WebClient
      $novo = $wc2.DownloadData($urlPrograma + '?t=' + (Get-Date).Ticks)
      $atual = [IO.File]::ReadAllBytes($PSCommandPath)
      $sha = New-Object Security.Cryptography.SHA256Managed
      $hNovo = [BitConverter]::ToString($sha.ComputeHash($novo))
      $hAtual = [BitConverter]::ToString($sha.ComputeHash($atual))
      if ($hNovo -ne $hAtual -and $novo.Length -gt 2000) {
        $txt = [Text.Encoding]::UTF8.GetString($novo).TrimStart([char]0xFEFF)
        $tk = $null; $erros = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($txt, [ref]$tk, [ref]$erros)
        if ($erros.Count -eq 0 -and $txt.Contains('PONTO PAUVAN - programa do servidor')) {
          Copy-Item $PSCommandPath ($PSCommandPath + '.anterior') -Force
          [IO.File]::WriteAllBytes($PSCommandPath, $novo)
          Log 'Programa atualizado sozinho (versão nova do GitHub). Reiniciando...'
          Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
          exit
        } else {
          Log ('Versão nova ignorada: o arquivo veio com erro (' + $erros.Count + ' erro(s)).')
        }
      }
    } catch {
      Log ('ERRO na atualização automática: ' + $_.Exception.Message)
    }
  }
  Start-Sleep -Seconds 20
}
