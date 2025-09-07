param(
  [Parameter(Mandatory=$true)] [string]$SESSDATA,
  [Parameter(Mandatory=$true)] [string]$BILI_JCT,
  [Parameter(Mandatory=$true)] [string]$DedeUserID = "",
  [Parameter(Mandatory=$true)] [string]$DedeUserIDCkMd5 = "",
  [string]$SID = "",
  [string]$BUVID3 = "",
  [int]$ExpiresDays = 360,
  [string]$OutPath = ".\Config\Login"
)

# Disable localized messages; keep ASCII output
$ErrorActionPreference = "Stop"

# Gets the directory where the scripts are located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $scriptDir) {
    $scriptDir = $PWD.Path
}

# Make sure the output path is based on the scripts directory and not the current working directory
if (-not [System.IO.Path]::IsPathRooted($OutPath)) {
    $OutPath = [System.IO.Path]::Combine($scriptDir, $OutPath)
}

function Get-MachineCode {
  $mb = (Get-CimInstance Win32_BaseBoard).SerialNumber
  $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).ProcessorId
  if (-not $mb)  { $mb  = "unknown" }
  if (-not $cpu) { $cpu = "unknown" }
  $mc  = ("PC.{0}.{1}" -f $mb,$cpu) -replace ' '
  [PSCustomObject]@{ MainBoard=$mb; CPU=$cpu; MachineCode=$mc }
}

function New-Cookie([string]$Name,[string]$Value,[DateTime]$Expires){
  $c = New-Object System.Net.Cookie
  $c.Name = $Name; $c.Value = $Value
  $c.Domain = ".bilibili.com"; $c.Path = "/"
  $c.Expires = $Expires
  return $c
}

function Write-BinaryFormatter([string]$FilePath,[object]$Obj){
  $fs = [System.IO.File]::Create($FilePath)
  try {
    $bf = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter
    $bf.Serialize($fs, $Obj)
    $fs.Flush()
  } finally { $fs.Dispose() }
}

# 以字节数组表示 FC_TAG（小端序），对应 C# 的 0xFC010203040506CF
$FC_TAG_BYTES = [byte[]](0xCF,0x06,0x05,0x04,0x03,0x02,0x01,0xFC)

function Read-BinaryFormatter([string]$FilePath){
  $fs = [System.IO.File]::OpenRead($FilePath)
  try {
    $bf = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter
    return $bf.Deserialize($fs)
  } finally { $fs.Dispose() }
}

function New-AesAlgo([string]$Password,[byte[]]$Salt){
  $pdb = New-Object System.Security.Cryptography.PasswordDeriveBytes($Password, $Salt, "SHA256", 1000)
  $alg = [System.Security.Cryptography.Rijndael]::Create()
  $alg.KeySize = 256
  $alg.Key     = $pdb.GetBytes(32)
  $alg.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  return $alg
}

function Encrypt-File([string]$InFile,[string]$OutFile,[string]$Password){
  $BUFFER_SIZE = 131072

  $fin  = [System.IO.File]::OpenRead($InFile)
  $fout = [System.IO.File]::Create($OutFile)
  try {
    $lSize = $fin.Length
    $bytes = New-Object byte[] $BUFFER_SIZE

    $rng  = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $IV   = New-Object byte[] 16
    $salt = New-Object byte[] 16
    $rng.GetBytes($IV); $rng.GetBytes($salt)

    $alg = New-AesAlgo -Password $Password -Salt $salt
    $alg.IV = $IV

    $fout.Write($IV,0,16)
    $fout.Write($salt,0,16)

    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $cout = New-Object System.Security.Cryptography.CryptoStream($fout, $alg.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
    $chash= New-Object System.Security.Cryptography.CryptoStream([System.IO.Stream]::Null, $hasher, [System.Security.Cryptography.CryptoStreamMode]::Write)

    $bw = New-Object System.IO.BinaryWriter($cout)
    $bw.Write([Int64]$lSize)
    $bw.Write($FC_TAG_BYTES)
    $bw.Flush()

    while (($read = $fin.Read($bytes,0,$bytes.Length)) -gt 0) {
      $cout.Write($bytes,0,$read)
      $chash.Write($bytes,0,$read)
    }

    $chash.Flush(); $chash.Close()
    $hash = $hasher.Hash
    $cout.Write($hash,0,$hash.Length)
    $cout.Flush()
    try { $cout.FlushFinalBlock() } catch {}
    $cout.Close()
  }
  finally {
    $fin.Dispose()
    $fout.Dispose()
  }
}

function Decrypt-File([string]$InFile,[string]$OutFile,[string]$Password){
  $BUFFER_SIZE = 131072
  $details = [PSCustomObject]@{ LSize=0; OutBytes=0; HashOK=$false; TagOK=$false; Error=$null }

  $fin  = [System.IO.File]::OpenRead($InFile)
  $fout = [System.IO.File]::Create($OutFile)
  try {
    $bytes = New-Object byte[] $BUFFER_SIZE

    $IV = New-Object byte[] 16;  [void]$fin.Read($IV,0,16)
    $salt = New-Object byte[] 16;[void]$fin.Read($salt,0,16)

    $alg = New-AesAlgo -Password $Password -Salt $salt
    $alg.IV = $IV

    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $cin  = New-Object System.Security.Cryptography.CryptoStream($fin, $alg.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
    $chash= New-Object System.Security.Cryptography.CryptoStream([System.IO.Stream]::Null, $hasher, [System.Security.Cryptography.CryptoStreamMode]::Write)

    $br = New-Object System.IO.BinaryReader($cin)
    $lSize = $br.ReadInt64()
    $details.LSize = $lSize
    $tagBytes = $br.ReadBytes(8)
    $details.TagOK = ($tagBytes.Length -eq 8) -and `
      [System.Linq.Enumerable]::SequenceEqual($tagBytes, $FC_TAG_BYTES)
    if (-not $details.TagOK) { throw "FC_TAG mismatch" }

    $numReads = [int]([math]::Floor($lSize / $BUFFER_SIZE))
    $slack    = [int]($lSize % $BUFFER_SIZE)

    for ($i=0; $i -lt $numReads; $i++) {
      $read = $cin.Read($bytes,0,$bytes.Length)
      if ($read -le 0) { break }
      $fout.Write($bytes,0,$read)
      $chash.Write($bytes,0,$read)
      $details.OutBytes += $read
    }
    if ($slack -gt 0) {
      $read = $cin.Read($bytes,0,$slack)
      $fout.Write($bytes,0,$read)
      $chash.Write($bytes,0,$read)
      $details.OutBytes += $read
    }

    $chash.Flush(); $chash.Close()
    $fout.Flush();  $fout.Close()

    $curHash = $hasher.Hash
    $oldHash = New-Object byte[] ($hasher.HashSize / 8)
    $r2 = $cin.Read($oldHash,0,$oldHash.Length)
    $details.HashOK = ($r2 -eq $oldHash.Length -and [System.Linq.Enumerable]::SequenceEqual($oldHash,$curHash))
  }
  catch {
    $details.Error = $_.Exception.Message
  }
  finally {
    $fin.Dispose()
    $fout.Dispose()
  }
  return $details
}

Write-Host ("ScriptDir: {0}" -f $scriptDir)
Write-Host ("WorkDir: {0}" -f (Get-Location).Path)
Write-Host ("OutPath: {0}" -f $OutPath)

# 1) machine code and password
$mc = Get-MachineCode
$secretKey = 'EsOat*^y1QR!&0J6'   # single-quoted to avoid &
$secret = $secretKey + $mc.MachineCode

Write-Host ("mb : {0}" -f $mc.MainBoard)
Write-Host ("cpu: {0}" -f $mc.CPU)
Write-Host ("mc : {0}" -f $mc.MachineCode)
Write-Host ("pwd.len: {0}" -f $secret.Length)

# 2) cookies -> serialize
$expires = [DateTime]::UtcNow.AddDays($ExpiresDays)
$cc = New-Object System.Net.CookieContainer
$cc.Add((New-Cookie -Name "SESSDATA" -Value $SESSDATA -Expires $expires))
$cc.Add((New-Cookie -Name "bili_jct" -Value $BILI_JCT -Expires $expires))
if ($DedeUserID)       { $cc.Add((New-Cookie -Name "DedeUserID" -Value $DedeUserID -Expires $expires)) }
if ($DedeUserIDCkMd5)  { $cc.Add((New-Cookie -Name "DedeUserID__ckMd5" -Value $DedeUserIDCkMd5 -Expires $expires)) }
if ($SID)              { $cc.Add((New-Cookie -Name "sid" -Value $SID -Expires $expires)) }
if ($BUVID3)           { $cc.Add((New-Cookie -Name "buvid3" -Value $BUVID3 -Expires $expires)) }

$tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString("N"))
Write-BinaryFormatter -FilePath $tmp -Obj $cc
$plainLen = (Get-Item $tmp).Length
Write-Host ("lSize(plain): {0} bytes" -f $plainLen)

# 3) encrypt -> OutPath
$destDir = Split-Path -Parent $OutPath
if ($destDir -and -not (Test-Path $destDir)) {
    Write-Host ("create dir: {0}" -f $destDir)
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}
if (Test-Path $OutPath) {
    Write-Host ("delete exist file: {0}" -f $OutPath)
    Remove-Item $OutPath -Force
}
Encrypt-File -InFile $tmp -OutFile $OutPath -Password $secret
Write-Host ("create file: {0}" -f $OutPath)
$encLen = (Get-Item $OutPath).Length
Write-Host ("enc.size: {0} bytes" -f $encLen)

# 4) immediate verify
$chk = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString("N"))
$verify = Decrypt-File -InFile $OutPath -OutFile $chk -Password $secret
Write-Host ("verify: TagOK={0} HashOK={1} OutBytes={2} LSize={3} Err={4}" -f $verify.TagOK,$verify.HashOK,$verify.OutBytes,$verify.LSize,$verify.Error)

# 5) list cookie names we intended to write
$names = @()
if ($SESSDATA)          { $names += "SESSDATA" }
if ($BILI_JCT)          { $names += "bili_jct" }
if ($DedeUserID)        { $names += "DedeUserID" }
if ($DedeUserIDCkMd5)   { $names += "DedeUserID__ckMd5" }
if ($SID)               { $names += "sid" }
if ($BUVID3)            { $names += "buvid3" }
Write-Host ("cookies: {0}" -f ($names -join ","))

# 6) cleanup
Remove-Item $tmp -ErrorAction SilentlyContinue
Remove-Item $chk -ErrorAction SilentlyContinue
Write-Host "done."