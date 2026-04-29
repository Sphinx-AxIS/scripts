$path = 'D:\Tim\Downloads\wireshark-portable-win64-3.6.5-19-setup.exe'
Get-Item -LiteralPath $path -Stream * |
  Where-Object { $_.Stream -notin @('::$DATA',':$DATA','$DATA') } |
  ForEach-Object {
    "`n==== [$($_.Stream)] ($(($_.Length)) bytes) ===="
    Get-Content -LiteralPath $path -Stream $_.Stream -Raw
  }