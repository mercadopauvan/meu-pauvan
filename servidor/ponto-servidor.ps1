# ===== PONTO PAUVAN - programa do servidor =====
# Lê as batidas do relógio iDFace (rede do mercado) a cada 30 segundos e manda para o APPS PAUVAN (planilha PONTO PAUVAN).
# Também acerta a hora do relógio pela hora do computador todo dia às 03:00
# e troca a fala do relógio conforme o horário (bom dia / bom almoço / boa tarde / bom descanso), puxando os áudios da nuvem.
# Também tira a foto da câmera do relógio quando o Celio pede no app (gestão › Hoje)
# e se atualiza sozinho: a cada 1 hora confere no GitHub (meu-pauvan/servidor) se tem versão nova.
# Também lê a temperatura do container (compartimento 3, sensor XT Painel) a cada 2 minutos e manda para a tela
# Gestão › Temperatura do container do APPS PAUVAN (acao contLeitura), e executa no aparelho os comandos que o Celio
# manda pelo app (ligar/desligar, automático/manual, temperaturas) em segundos, por uma escuta em processo separado
# (container-log.txt). Se o sensor mudar de IP, procura ele na rede pelo nome e passa a usar o IP novo (container-ip.txt).
# Feito pelo chat APPS PAUVAN em 22 e 23/11/2026.
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
# container: IP do sensor (pode trocar no ponto-config.txt com CONTAINER_IP=...)
$contIp = '192.168.1.126'
if ($cfg.CONTAINER_IP) { $contIp = $cfg.CONTAINER_IP }
# se o sensor mudar de IP, o programa procura ele na rede pelo nome (id) e guarda o IP novo em container-ip.txt
$contId = 'XT-A5100C'
if ($cfg.CONTAINER_ID) { $contId = $cfg.CONTAINER_ID }
$arqContIp = Join-Path $pasta 'container-ip.txt'
if (Test-Path $arqContIp) { $tIp = ([string](Get-Content $arqContIp -Raw)).Trim(); if ($tIp -match '^\d+\.\d+\.\d+\.\d+$') { $contIp = $tIp } }
$contProcurado = [DateTime]::MinValue
# procura o sensor em todas as redes do PC (e na do IP antigo): pergunta /api/status de todos os endereços ao mesmo tempo (~3 s)
function ContProcurar($idSensor, $ipAtual) {
  Add-Type -AssemblyName System.Net.Http
  $prefixos = @()
  if ($ipAtual -match '^(\d+\.\d+\.\d+)\.\d+$') { $prefixos += $matches[1] }
  try {
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      if ([string]$ni.OperationalStatus -ne 'Up') { continue }
      foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
        $a = $ua.Address.ToString()
        if ([string]$ua.Address.AddressFamily -eq 'InterNetwork' -and $a -match '^(10|192\.168|172\.(1[6-9]|2\d|3[01]))\.' -and $a -match '^(\d+\.\d+\.\d+)\.\d+$') { $prefixos += $matches[1] }
      }
    }
  } catch {}
  $prefixos = @($prefixos | Select-Object -Unique)
  $hc = New-Object System.Net.Http.HttpClient
  $hc.Timeout = [TimeSpan]::FromSeconds(3)
  $ips = @(); $tarefas = @()
  foreach ($pf in $prefixos) {
    for ($i = 1; $i -le 254; $i++) {
      $ip = $pf + '.' + $i
      $ips += $ip
      $tarefas += $hc.GetStringAsync('http://' + $ip + '/api/status')
    }
  }
  try { $null = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tarefas, 6000) } catch {}
  $achado = $null
  for ($k = 0; $k -lt $tarefas.Count; $k++) {
    if ([string]$tarefas[$k].Status -eq 'RanToCompletion') {
      try {
        $j = $tarefas[$k].Result | ConvertFrom-Json
        if ($j.id -and ([string]$j.id -eq $idSensor) -and ($null -ne $j.temp)) { $achado = $ips[$k] }
      } catch {}
    }
  }
  $hc.Dispose()
  return $achado
}
$contConferido = [DateTime]::MinValue
$contFalhas = 0

$contJob = $null
$contJobIni = [DateTime]::MinValue
# container: ESCUTA DE COMANDOS (processo separado, para nunca atrasar o ponto). Fica com uma chamada sempre esperando no
# APPS PAUVAN (acao contEspera, até ~17 s); quando o Celio toca um botão na tela do container, a chamada volta na hora com o
# comando, a escuta executa no aparelho (XT Painel) pelo mesmo endereço que a página dele usa (POST /api/save) e confirma.
# Só mexe em: ventilador (manual_cmd), modo (mode) e temperaturas do automático (t_on/t_off). Nunca mexe no Wi-Fi do aparelho.
# Registro próprio: container-log.txt nesta pasta.
$contEscuta = {
  param($url, $chave, $ip, $pasta)
  $ErrorActionPreference = 'Stop'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $arq = Join-Path $pasta 'container-log.txt'
  function JLog($m) {
    try {
      Add-Content -Path $arq -Value ((Get-Date -Format 'dd/MM/yyyy HH:mm:ss') + '  ' + $m) -Encoding UTF8
      if ((Get-Item $arq).Length -gt 1MB) { Move-Item $arq ($arq + '.old') -Force }
    } catch {}
  }
  function JNuvem($dados) {
    $dados.chave = $chave
    $json = $dados | ConvertTo-Json -Depth 6 -Compress
    return Invoke-RestMethod -Uri $url -Method Post -ContentType 'text/plain; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 90
  }
  function JStatus {
    $s = Invoke-RestMethod -Uri ('http://' + $ip + '/api/status') -TimeoutSec 8
    if ($s -is [string]) { $s = $s | ConvertFrom-Json }
    return $s
  }
  function ContComando($c, $st) {
    $id = [string]$c.id
    try {
      $op = [string]$c.op
      $on = 0; $off = 0
      if ($op -eq 'LIGAR' -or $op -eq 'DESLIGAR') {
        if ($st -and $st.mode_auto) { return @{ id = $id; ok = $false; erro = 'o aparelho está no AUTOMÁTICO: passe para MANUAL antes de ligar/desligar' } }
        $b = @{ manual_cmd = ($op -eq 'LIGAR') }
      } elseif ($op -eq 'AUTO') { $b = @{ mode = 'AUTO' } } elseif ($op -eq 'MANUAL') { $b = @{ mode = 'MANUAL' } } elseif ($op -eq 'LIMITES') {
        $on = [double]$c.tOn; $off = [double]$c.tOff
        if ($off -ge $on) { return @{ id = $id; ok = $false; erro = 'o desliga tem que ser menor que o liga' } }
        $b = @{ t_on = $on; t_off = $off }
      } else { return @{ id = $id; ok = $false; erro = ('comando desconhecido: ' + $op) } }
      $json = $b | ConvertTo-Json -Compress
      $null = Invoke-RestMethod -Uri ('http://' + $ip + '/api/save') -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 8
      Start-Sleep -Seconds 2
      $n = JStatus
      $ok = $true
      if ($op -eq 'LIGAR') { $ok = [bool]$n.relay } elseif ($op -eq 'DESLIGAR') { $ok = -not [bool]$n.relay } elseif ($op -eq 'AUTO') { $ok = [bool]$n.mode_auto } elseif ($op -eq 'MANUAL') { $ok = -not [bool]$n.mode_auto } elseif ($op -eq 'LIMITES') { $ok = ([math]::Abs([double]$n.t_on - $on) -lt 0.01) -and ([math]::Abs([double]$n.t_off - $off) -lt 0.01) }
      if ($ok) { return @{ id = $id; ok = $true } }
      return @{ id = $id; ok = $false; erro = 'o aparelho recebeu, mas não mudou (confira na página dele)' }
    } catch {
      return @{ id = $id; ok = $false; erro = ('aparelho não respondeu: ' + $_.Exception.Message) }
    }
  }
  JLog 'Escuta de comandos do container iniciada.'
  $ult = ''; $fUlt = $null
  while ($true) {
    try {
      $t0 = Get-Date
      $r = JNuvem @{ acao = 'contEspera'; comp = '3' }
      if ($r -and $r.ok -eq $false) { JLog ('APPS PAUVAN recusou a escuta: ' + $r.erro); Start-Sleep -Seconds 60; continue }
      if (-not ($r -and $r.cmd -and $r.cmd.id)) { if (((Get-Date) - $t0).TotalSeconds -lt 5) { Start-Sleep -Seconds 5 }; continue }   # proteção: nunca martelar o servidor
      if ($r -and $r.cmd -and $r.cmd.id) {
        if ([string]$r.cmd.id -eq $ult) {
          # já executado, mas a confirmação não chegou: manda de novo, sem repetir no aparelho
          if ($fUlt) { $null = JNuvem @{ acao = 'contFeito'; comp = '3'; cmdFeito = $fUlt } }
          Start-Sleep -Seconds 5
        } else {
          $ult = [string]$r.cmd.id
          $st = $null
          try { $st = JStatus } catch {}
          $fUlt = ContComando $r.cmd $st
          JLog ('Comando ' + $r.cmd.op + ' (' + $r.cmd.quem + ') -> ' + $(if ($fUlt.ok) { 'feito' } else { 'ERRO ' + $fUlt.erro }))
          # confirma e já manda a leitura nova (a tela mostra o ventilador/modo atualizado)
          $d = @{ acao = 'contLeitura'; comp = '3'; versao = 2; soLeitura = 1; cmdFeito = $fUlt }
          try {
            $s = JStatus
            $d.temp = [double]$s.temp; $d.relay = [bool]$s.relay; $d.auto = [bool]$s.mode_auto
            $d.tOn = $s.t_on; $d.tOff = $s.t_off; $d.wifi = [bool]$s.wifi_ok; $d.mqtt = [bool]$s.mqtt_ok; $d.sensor = [string]$s.id
          } catch {
            $d.erro = 'sensor sem resposta: ' + $_.Exception.Message
          }
          $null = JNuvem $d
        }
      }
    } catch {
      JLog ('ERRO na escuta: ' + $_.Exception.Message)
      Start-Sleep -Seconds 15
    }
  }
}
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
  # 7) temperatura do container (compartimento 3): a cada 2 min lê o sensor e manda para o APPS PAUVAN.
  #    Fica separado do ponto: se o sensor estiver desligado (degelo) ou fora do ar, só registra e segue.
  #    Os comandos do app (ligar/desligar etc.) NÃO passam por aqui: quem executa é a escuta ($contEscuta), em processo separado.
  if (((Get-Date) - $contConferido).TotalSeconds -ge 120) {
    $contConferido = Get-Date
    try {
      $d = @{ acao = 'contLeitura'; comp = '3'; versao = 2; soLeitura = 1 }
      try {
        $s = Invoke-RestMethod -Uri ('http://' + $contIp + '/api/status') -TimeoutSec 8
        if ($s -is [string]) { $s = $s | ConvertFrom-Json }
        if ($null -eq $s.temp) { throw 'leitura veio sem temperatura' }
        $d.temp = [double]$s.temp
        $d.relay = [bool]$s.relay
        $d.auto = [bool]$s.mode_auto
        $d.tOn = $s.t_on
        $d.tOff = $s.t_off
        $d.wifi = [bool]$s.wifi_ok
        $d.mqtt = [bool]$s.mqtt_ok
        $d.sensor = [string]$s.id
        if ($contFalhas -gt 0) { Log ('Sensor do container voltou a responder: ' + $s.temp + ' graus') }
        $contFalhas = 0
      } catch {
        $contFalhas++
        $d.erro = 'sensor sem resposta: ' + $_.Exception.Message
        if ($contFalhas -eq 1) { Log ('Sensor do container sem resposta: ' + $_.Exception.Message) }
        # 2 falhas seguidas (~4 min): procura o sensor na rede (no máximo 1 vez a cada 30 min)
        if ($contFalhas -ge 2 -and ((Get-Date) - $contProcurado).TotalMinutes -ge 30) {
          $contProcurado = Get-Date
          $novoIp = $null
          try { $novoIp = ContProcurar $contId $contIp } catch { Log ('ERRO ao procurar o sensor na rede: ' + $_.Exception.Message) }
          if ($novoIp -and ($novoIp -ne $contIp)) {
            $d.ipMudou = $contIp + ' -> ' + $novoIp
            Log ('Sensor do container achado em outro IP: ' + $contIp + ' -> ' + $novoIp)
            $contIp = $novoIp
            try { Set-Content -Path $arqContIp -Value $novoIp -Encoding ASCII } catch {}
            if ($contJob) { try { Stop-Job $contJob; Remove-Job $contJob -Force } catch {}; $contJob = $null }
            $contJobIni = [DateTime]::MinValue
            $contConferido = (Get-Date).AddSeconds(-120)   # lê no IP novo já na próxima volta
          } elseif (-not $novoIp) {
            $d.erro = $d.erro + ' (procurei o ' + $contId + ' na rede e não achei)'
            Log ('Procurei o sensor ' + $contId + ' na rede e não achei.')
          }
        }
      }
      $null = Nuvem $d
    } catch {
      Log ('ERRO no container: ' + $_.Exception.Message)
    }
  }
  # 7b) escuta de comandos do container: se não estiver rodando, (re)inicia (no máximo 1 vez a cada 2 min)
  if ((($null -eq $contJob) -or ($contJob.State -ne 'Running')) -and (((Get-Date) - $contJobIni).TotalSeconds -ge 120)) {
    $contJobIni = Get-Date
    try {
      if ($contJob) { Remove-Job $contJob -Force -ErrorAction SilentlyContinue; Log 'Escuta do container tinha parado; reiniciando.' }
      $contJob = Start-Job -ScriptBlock $contEscuta -ArgumentList $cfg.URL_APP, $cfg.CHAVE, $contIp, $pasta
    } catch {
      Log ('ERRO ao iniciar a escuta do container: ' + $_.Exception.Message)
    }
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
          if ($contJob) { try { Stop-Job $contJob; Remove-Job $contJob -Force } catch {} }
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
