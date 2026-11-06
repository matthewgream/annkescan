# annkescan

One of three tools for an archive of Annke camera clips, each working on what the one before left:

| | |
|---|---|
| [annkepull](https://github.com/matthewgream/annkepull) | fetches the event clips from the cameras' SD cards into the archive, every 6 hours |
| **annkescan** | flags the people, animals and vehicles in each clip, with a daily report to MQTT |
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
| `widewatch` | a trial for the wide camera, run by hand (see [Wide](#wide-trial)); also needs `mqtt` |
| `annkescan.service` | the worker, `Nice=19`, `CPUSchedulingPolicy=idle`, `IOSchedulingClass=idle` |
| `annkescan-storage.service` | gate: it needs `opt-storage-disk.mount` |

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

## Wide (trial)

The wide camera has no clips: rtsptomqtt on vader publishes a still every 30 s over MQTT
(`snapshots/imagedata`, then `snapshots/metadata` with its time), and workshop's mosquitto bridges them in,
so a still crosses the network once for every subscriber here (the archiver, and this). `widewatch` is a
trial, run by hand in a terminal for as long as it takes for cars to come by. It puts each still through
YOLO26 on the cars zone (`wide-mask-cars.png`, plus a margin above for the bodies of cars at the far end),
a line per still:

```sh
./widewatch        # Ctrl-C to stop; a summary every hour and at the end
```

```
time     still          size    zone         | yolo26                     | took
16:28:21 20261028152756 1.87MB  same  0/202  | 8.0s car 0.83              | 9.4s  << vehicle
```

`still` is its time (UTC, as the archiver names it); `zone` the change since the last still (blocks whose
brightness moved, the zone's overall shift taken out); then what it found (vehicles whose wheels are in
the zone at the threshold or better), with its time, and the time from arrival to done. A still with no
change in the zone is not searched: whatever was there still is. A vehicle counts (`<< vehicle`) when a
quarter or more of the change blocks under it changed, so it came or moved; one in a still part of the
zone is shown as `static`, and not counted. The first night showed why: YOLO26 took a dark patch at the
top of the zone for a car 18 times (0.48 to 0.70), every one on an unchanged still, and the zone changed
on only 37 of 916 stills. A damaged still (much smaller than the last few) is not searched either. A
search takes ~8 s on workshop (~1 s without); if it is still busy when the next still comes, only the
newest waits. YOLOX ran beside it at first and was dropped within the hour: a "car" at the zone's left
edge, again and again.

In its folder (`--out`, default `/opt/storage/disk/widewatch`): `latest.jpg`, the last still's zone with the
boxes; the stills where something was found, kept like that by day; and `widewatch.jsonl`, every line. It
takes masks, models and the threshold from annkescan's config.

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
make install      # models (fetched, checksummed), tool + npm dependencies to /usr/local/lib/annkescan, config, units
make status       # the worker and its last log lines
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
