# 98S3 1.1.9 ファームウェア

対象: ESP32-S3 N16R8。ESP-IDF 5.5.0 でビルドしています。

## 変更点

- ニューリリース

## 新規書き込み（結合版）

`98S3-public-1.1.9-20261106.bin` を **0x0** に書き込みます。全体を書き込むため、設定が失われる場合があります。

```sh
python -m esptool --chip esp32s3 --port COM6 --baud 460800 write_flash 0x0 98S3-public-1.1.9-20261106.bin
```

## 設定を維持する更新

`pc98s3-app.bin` を **0x10000** に書き込みます。

```sh
python -m esptool --chip esp32s3 --port COM6 --baud 460800 write_flash 0x10000 pc98s3-app.bin
```

COM 番号は実機に合わせてください。
