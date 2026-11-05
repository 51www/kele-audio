# M9.0 spike：用 curl 模拟 Edge TTS WebSocket 升级握手
$ErrorActionPreference = 'Stop'
$ts = [long](([DateTime]::UtcNow.Ticks - 621355968000000000) / 10000000)
$t = $ts + 11644473600
$t = $t - ($t % 300)
$t100 = "${t}0000000"
$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$t100" + '6A5AA1D4EAFF4E9FB37E23D68491D6F4')) | ForEach-Object { $_.ToString('X2') }) -join ''
$keyBytes = New-Object byte[] 16
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($keyBytes)
$key = [Convert]::ToBase64String($keyBytes)
$url = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&ConnectionId=ABCDEF0123456789ABCDEF0123456789&Sec-MS-GEC=$hash&Sec-MS-GEC-Version=1-143.0.3650.75"
Write-Host "GEC=$hash"
curl.exe -s -i --max-time 8 --noproxy "*" $url `
  -H "Connection: Upgrade" `
  -H "Upgrade: websocket" `
  -H "Sec-WebSocket-Version: 13" `
  -H "Sec-WebSocket-Key: $key" `
  -H "Origin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold" `
  -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0" | Select-Object -First 8
