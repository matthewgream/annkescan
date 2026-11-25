# annkescan

One of three tools for an archive of Annke camera clips, each working on what the one before left:

| | |
|---|---|
| [annkepull](https://github.com/matthewgream/annkepull) | fetches the event clips from the cameras' SD cards into the archive, every 6 hours |
| **annkescan** | flags the people, animals and vehicles in each clip, with a daily report to MQTT; and vehicles at the wide camera, as its stills come |
| [annkeserv](https://github.com/matthewgream/annkeserv) | browses the archive over HTTP, with what annkescan found |

They share nothing but the archive's files (`<archive>/<camera>/<YYYYMMDD>/recording_<...>.mp4`, with
annkescan's `.json` and `.jpg` beside each clip), so each runs on its own.

Flags the people, animals and vehicles seen in the camera archive's clips (those `annkepull` fetches), for
`annkeserv` to show. A long-running worker at idle priority: it works through the clips that have no
result yet, newest first, so a new clip is flagged soon after it arrives and the backlog is done in the
gaps; it looks for new clips every `rescan` seconds (default an hour: annkepull brings them every 6 hours).

Per clip it decodes the keyframes (one every 8 s on side, 3.8 s on front), runs an object detector on each
-- YOLOX-S or YOLO26s, trained on COCO, through ONNX Runtime (see [Detectors](#detectors)) -- and writes
beside the clip:

| | |
|---|---|
| `recording_<...>.json` | `{"seen": {"people": 0.85, "animals": 0.47}, "detections": [...], "ignored": [...], ...}` -- written last, so it marks the clip done |
| `recording_<...>.jpg` | only when something was seen: the keyframe with the best detection, 640 wide, boxes drawn (people red, animals yellow, vehicles cyan) |

`seen` is the best score per group; `model` the detector; `duration` the clip's length in seconds;
`detections` lists each one counted (`t` seconds into the clip, class, score, box in the clip's pixels)
and `ignored` those left out, with `why` (`zone` or `static`). To have clips done again -- after changing
masks or settings -- remove their `.json`.

## Report

Once a day, at `report-at` (default 06:00, local time), a report of the clips done since the last one goes to
MQTT (`mqtt-server`, empty for none), not retained, on `<mqtt-topic>/<YYYYMMDD>` (default `camera/detect/...`).
annkepull brings clips every 6 hours, so the report waits for a time of day rather than going each time they
are done: the morning's pull (04:00-04:30, done in some minutes) and its clips are done by then, and the
wait between looks for clips ends at that time, so there is one last look first. If clips are still being
done then, it goes when they are. What it has so far is kept in `/var/lib/annkescan/report.json`, so a
restart in the day loses nothing. With `report-at` empty, it goes each time the clips are done.

```json
{"day": "20261030", "from": "20261029042337", "to": "20261030041512",
 "clips": 92, "seconds": 11523, "failed": 0, "people": 3, "animals": 1, "vehicles": 0,
 "cameras": {"front": {"clips": 46, "seconds": 4980, "failed": 0, "people": 2, "animals": 1, "vehicles": 0}, "side": {...}},
 "summary": "all 92 clips, 3h12m: people 3, animals 1\nfront 46 clips, 1h23m: people 2, animals 1\nside 46 clips, 1h49m: people 1",
 "people_or_animals": true}
```

The counts are of clips (a clip with three people in it counts once), `seconds` their total length.
mqtt-watchdog notifies on `people_or_animals` (the `house` instance: ntfy, default priority, with the
summary). Its alerts are states -- a field holding a value -- not events, so a report with people or
animals in it is sent twice, `true` and then `false`, as zigbee's test button does: one notification per
report, and nothing left held for the next day's to be lost behind.

| | |
|---|---|
| `annkescan` | the tool (Node; npm dependency `onnxruntime-node`; uses `ffmpeg`, `ffprobe`, and `mosquitto_pub` for the report) |
| `annkescan-realtime` | the wide camera's stills as they come (see [Wide](#wide-realtime)); also needs `mqtt` |
| `annkescan.service` | the worker, `Nice=19`, `CPUSchedulingPolicy=idle`, `IOSchedulingClass=idle` |
| `annkescan-realtime.service` | it, at the usual priority |
| `annkescan-storage.service` | gate: both need `opt-storage-disk.mount` |

## What counts

- **Groups, not species.** People; animals (bird, cat, dog, horse, sheep, cow); vehicles (bicycle, car,
  motorcycle, bus, truck). At these distances the species is often wrong -- a white dog and a cat both
  scored as "sheep" -- while the group is right. A tractor comes out as a truck.
- **Zones.** With `masks=<dir>`, a detection counts only where its bottom centre (feet, wheels) is white in
  `<camera>-mask.png` (every group) or `<camera>-mask-<group>[-and-<group>].png` (`cars` is vehicles); a
  group's own mask overrides the general one for that group, so `side-mask-vehicles.png` can paint out
  fixed clutter that is only ever mistaken for a vehicle while people and animals keep `side-mask.png`.
  Only the part of the frame the masks cover is decoded and searched. Paint masks over a full-size
  snapshot of the camera; any size of the same shape works. They are re-read when they change.
- **Not parked.** A vehicle in the same place in every keyframe is ignored (something parked, or a round
  lid the model took for a car): the cameras record on motion, so what set the clip off moves. People and
  animals standing still still count.
- **Detail.** The model sees 640x640. `tiles-<camera>=2` searches overlapping 640 px tiles of a frame
  scaled to two tiles wide: four times the pixels per object for about twice the time. On side, at one
  tile, a dog (0.18) and a cat in the yard were missed; at two they were found (0.47, 0.68).
- `threshold` (default 0.4) is the score a detection needs. Lowering it on side brought the brick stacks
  and pallets in as "cars" well before it found the dog.
- **Not a known false positive.** See below.

## Detectors

| | |
|---|---|
| `yolox` | YOLOX-S, from the OpenCV model zoo (2022). The first, and still what the clips recorded before `yolo26-from` get. |
| `yolo26` | YOLO26s (Ultralytics, AGPL-3.0), as exported to ONNX by onnx-community. The clips recorded from `yolo26-from` (`YYYYMMDDHHMMSS`, the time in their names) get it. |

On workshop YOLO26 took over at 2026-10-28 15:40, for new clips only: the backlog, all recorded before,
stays with YOLOX, so there is one switchover at a time rather than a mix through the archive, and results
already written stay as they are. Each result's `model` says which it got.

Why: in a bake-off on 57 clips (known catches, the screened false positives, YOLOX's flags and empty
clips), YOLO26 flagged none of the screened false positives even without the screens, and nothing on the
empty clips. Of the clips YOLOX flagged, it left out eight that were wrong (a log by the front tarp as a
"dog" three times, a downpipe and a night reflection in the window as a "person", a patch by the old barn
as a "car", two heads at side's bottom edge as "birds"), and got a person YOLOX took for a dog and a
tractor's driver. What it costs: it missed side's tractor at night (0.26 to YOLOX's 0.49) and the robot
mower on one day, and the cat only just counts (0.41). D-FINE-S found more but added false positives on
half the screened clips and most of the empty ones; DEIMv2-S did much the same, three times slower.

Both missed what is only on screen between keyframes (a person at the end of a clip, a quad behind the
foliage): that is the sampling, not the detector.

To see what either makes of a clip: `make test MODEL=yolox CLIP=...` (or `MODEL=yolo26`).

## Wide (realtime)

The wide camera has no clips: rtsptomqtt on vader publishes a still every 30 s over MQTT
(`snapshots/imagedata`, then `snapshots/metadata` with its time), and workshop's mosquitto bridges them in,
so a still crosses the network once for every subscriber here (the archiver, and this).
`annkescan-realtime` looks at each as it comes and says whether vehicles are there -- not how many: one van
comes out as two boxes (the whole of it and its cab), and parked cars hide each other.

For each still:

- **Damage.** The camera sometimes cuts a keyframe short, and below the cut the still is flat (pale) or in
  magenta or purple blocks. It is looked for in the lower two thirds of a small copy of the whole still: a
  fifth or more of it with green under both red and blue (real stills are green, or grey under the IR), or
  flatter than 6 (the mean difference between neighbours, of 255). A damaged still is not looked at
  further, nor compared with. Over ten days the damaged had 40% or more magenta or were flatter than 4.1;
  the whole -- day, night, fog -- had none and were 9 or more. (The trial went by size, much smaller than
  the last few: at night in fog whole stills shrink as much, and 45 of its 69 were whole; it missed 2.)
- **Change** in the zone since the last good still: blocks whose brightness moved, the zone's overall shift
  taken out. None, and it is not searched: whatever was there still is.
- **Search**: YOLO26 on the cars zone (`wide-mask-cars.png`, plus a margin above for the bodies of cars at
  the far end), for vehicles whose wheels are in the zone at the threshold or better. One with a quarter or
  more of the change blocks under it changed has moved (or come); one where nothing changed is `static`.

Presence follows from that:

- Absent, and a vehicle moved: present, one **arrived**. A static one does not count: the trial's false
  positives (a dark patch at the top of the zone, at dusk or night, 3 in 5000 searches) were all static.
- Present, and nothing found where the vehicles were and that changed: **leaving**. The next still is
  searched whatever its change; nothing again, and they **left**, as of the first. Nothing found where
  nothing changed is the detector missing a parked car.
- After a start it takes up from the last heartbeat; the first still has no change to go by, so whatever
  is found.

The first van, 2026-11-11: there at 09:32:58 (UTC) and not at 09:32:28, moved on the next as it settled; for
1h28m every still was unchanged, or changed a little (doors, people) and was searched and found static,
nine times; at 11:00:58 the zone changed and nothing was found, and 11:01:28 confirmed it.

Out, each still:

| | |
|---|---|
| `camera/wide` | retained: `{"time": "<still>", "present": true, "since": "<still it changed at>", "movement": false, "still": "searched", "boxes": [...]}`. `still` is `searched`, `same` or `damaged`; `movement` that a vehicle moved in this one (one came, a second beside one parked, one turning); `boxes` those last found while present, in the still's pixels. One per still, so also the heartbeat. |
| `snapshot_<time>.json` | beside the still in the archiver's folder (`realtime-snapshots`), only when a vehicle is present or found (most of the year, none), as the clips' results: `{"time", "model", "present", "since", "movement", "still", "seen": {"vehicles": 0.89}, "detections": [...], "change": {...}}` |

In `realtime-log` (`/opt/storage/disk/weather/detections` on workshop, beside the archive): `latest.jpg`,
the last still's zone with the boxes; the stills where something was found, kept like that by day, at
most one each `realtime-keep` minutes (15) while the number found stays the same, since a parked car is
found all day and the archive has every still; and `realtime.jsonl`, a line per still. The journal has
the stills searched, the damaged, the arrivals and departures, and a summary each hour:

```
20261111093258 change 5/202 | car 0.89 moved, car 0.85 moved | 4.0s of 5.3s  << arrived
20261111110058 change 7/202 | - | 3.8s of 5.1s  -- nothing where they were: the next is searched
20261111110128 same 0/202 | - | 4.0s of 5.3s  << left (there from 20261111093258, 1h28m)
```

A still takes ~1.2 s to decode and check, and a search ~4 s more; if it is still busy when the next comes,
only the newest waits. It runs at the usual priority, ahead of annkescan's clips. The archiver's timelapse
takes only the `.jpg` stills from the folder. It grew from `widewatch`, a trial run by hand from 2026-10-28
until the first van; YOLOX ran beside that for the first hour and was dropped for a "car" at the zone's left
edge, again and again.

## False positives

Some things are taken for something else again and again, but not in every keyframe, so the "not parked"
rule misses them: on side, the lid of the waste tank is a "car" (0.41-0.69) in one keyframe of a clip
here and there, always in much the same box. To screen one out, copy a result that shows it into the
`screens` folder:

```sh
cp /opt/storage/camera/side/20261006/recording_20261006131456.json /opt/annkescan/annkescan.workshop/screens/
```

Every detection in a file there becomes a known false positive for that result's camera (if the clip also
caught something real, delete that entry from the copy). A detection counts as the same when it is of the
same group on the same camera and in the same place: its box's centre inside the false positive's box, at
no more than twice or half its size. (Not box overlap: on a small, distant box a shift of a few pixels
halves it -- a turquoise thing at the back of side's view, 98x29 one day and 131x32 the next, overlapped by
0.39.) A person by the lid is a different group, so still counts. A matched detection is listed in
`ignored` with `"why": "screen"` and the file it matched.

When the folder changes, every result already written is checked against it again -- from what the
result recorded, without detecting again -- so dropping a file in clears the past too, and taking it out
brings those detections back; thumbnails are redrawn or removed to match. The folder is watched
(inotify), so that happens within seconds of the change, even when there are no clips to do. Which screens
the archive was last checked against is kept in `/var/lib/annkescan`, so a restart does not check it all
again.

## Cost

On workshop (Celeron 847, 2 cores, no AVX): ~0.4 s to decode a 4K HEVC keyframe and ~4.2 s per 640 px
search with YOLOX, ~3.6 s with YOLO26. So ~15-20 s per front clip (whole frame) and ~25-35 s per side clip (two tiles), ~45 minutes a day
for both cameras, and a few days for the whole archive. `days=<n>` limits it to recent clips.

## Install

```sh
make install      # models (fetched, checksummed), tools + npm dependencies to /usr/local/lib/annkescan, config, units
make status       # the worker, annkescan-realtime, and their last log lines
make test CLIP="/opt/storage/camera/side/<YYYYMMDD>/recording_<...>.mp4"   # what a clip would get, writing nothing
```

Config goes to `/etc/default/annkescan`; a per-host `annkescan.<hostname>.cfg` is used instead of
`annkescan.cfg` when present. A host's masks can sit beside it in `annkescan.<hostname>/` (with the
snapshots they were painted on); like the per-host config, that folder is not committed.

## Notes

- YOLOX expects BGR, 0..255, unnormalised, letterboxed with 114, and its output is per anchor of
  80x80/40x40/20x20 grids (strides 8/16/32): centre and size in cells, objectness, then the 80 COCO
  class scores. Decoding and non-maximum suppression are done here.
- YOLO26 expects RGB, 0..1 (`pixel_values`), and is end to end: 300 queries, each with 80 class logits
  (a sigmoid makes them scores) and a box as centre and size in fractions of the input. Non-maximum
  suppression is still done across tiles.
- ONNX Runtime's prebuilt binaries run on this CPU without AVX (TensorFlow's and recent PyTorch's need it);
  `make install` keeps only the linux/x64 ones.
- Keyframe times come from the packet flags (`ffprobe -show_entries packet`), without decoding.

## License

CC BY-NC-SA 4.0 — see [LICENSE](LICENSE).
