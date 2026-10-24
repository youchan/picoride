# PicoRuby/FemtoRuby IDE for ESP32 / Raspberry Pi Pico

This is PicoRuby/FemtoRuby development environment for ESP32 and Raspberry Pi Pico
(R2P2-ESP32 / R2P2).
This IDE can do as following

- Edit source codes(.c .h .rb) for mrbgem as a project
- Build image
- Install image to your device

## Setup

The app itself runs natively on your machine (Ruby). Docker is only used to run
the firmware builds. There is one builder image per target family; build the
one(s) you need once up front:

```bash
bundle install
docker build -t picoride-builder-esp32 docker/esp32   # ESP32 (ESP-IDF)
docker build -t picoride-builder-pico  docker/pico    # Raspberry Pi Pico (pico-sdk)
```

The server picks the image from the project's target (Settings dialog):
`esp32*` targets use `picoride-builder-esp32`, `pico` / `pico_w` / `pico2` /
`pico2_w` use `picoride-builder-pico`. Image names can be overridden with
`PICORIDE_ESP32_BUILDER_IMAGE` / `PICORIDE_PICO_BUILDER_IMAGE`.

If PicoRuby bumps its required pico-sdk version, the Pico build stops with
"pico-sdk X is not checked out!". Rebuild the image with
`docker build --build-arg PICO_SDK_VERSION=X -t picoride-builder-pico docker/pico`.

### Raspberry Pi Pico notes

- A Pico build produces a `.uf2`. Use "UF2をダウンロード" in the menu bar, then
  hold BOOTSEL while plugging in the Pico and copy the file to the drive that
  appears (`RPI-RP2` / `RP2350`).
- Unlike ESP32, `app/` is not baked into the firmware. Transfer it with
  "app/ をアップロード" on the Terminal tab.
- `pico` / `pico_w` (RP2040) support only FemtoRuby (mruby/c);
  `pico2` / `pico2_w` support both FemtoRuby and PicoRuby (mruby).

## Run

```bash
./bin/server
```

Open http://localhost:4567 . On first load, open a project via File > Open
Project (or the dropdown in the menu bar) and browse to, or create, a
directory on disk — it gets an `app/` and `build_config.rb` automatically.
Opened projects are remembered in `~/.picoride/project.toml`, so the last one
you had open reopens automatically on the next server start.

## Troubleshooting

### `Failed to execute 'open' on 'SerialPort': Failed to open serial port.`

This happens when connecting to the device from the Terminal tab (Web Serial
API). On Linux, check `chrome://device-log` right after the failed attempt to
see the actual OS-level error:

- **`FILE_ERROR_ACCESS_DENIED`**: your user isn't (yet) in the `dialout` group
  with an active session, so the browser process can't open `/dev/ttyACM*` /
  `/dev/ttyUSB*`.
  ```bash
  sudo usermod -aG dialout $USER
  ```
  Adding yourself to the group is not enough by itself — an already-running
  login session (and any browser already open in it) still has the old group
  list. **Log out and back in (or reboot)** so the new group membership takes
  effect, then try connecting again.
- If the port isn't held by anything and permissions look right but it still
  fails, check whether another process/service is holding the port open:
  `sudo lsof /dev/ttyACM0` (or `/dev/ttyUSB0`), and whether `ModemManager` or
  `brltty` is running and probing it (`systemctl status ModemManager brltty`).

