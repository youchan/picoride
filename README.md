# PicoRuby/FemtoRuby ESP32 IDE

This is PicoRuby/FemtoRuby for ESP32 development environment.
This IDE can do as following

- Edit source codes(.c .h .rb) for mrbgem as a project
- Build image
- Install image to your device

## Setup

The app itself runs natively on your machine (Ruby). Docker is only used to run
`idf.py build` / `rake setup_xxx`, so it needs to be built once up front:

```bash
bundle install
docker build -t picoride-builder .
```

## Run

```bash
./bin/server
```

Open http://localhost:4567 . On first load, open a workspace via File > Open
Workspace and enter the absolute path to a directory on disk that will hold
your projects (sub-folders, each with an `app/`). This isn't persisted across
server restarts — you'll open it again next time.

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

