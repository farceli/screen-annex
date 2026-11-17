# Synthetic H.264 sample

`sample.h264` contains five generated frames from the FFmpeg `testsrc2` pattern
(128 × 256 at 30 fps), encoded with libx264. It is shared by the Swift, macOS
video and Windows MP4 regression tests. It contains one keyframe, four delta
frames and the H.264 parameter sets. All Annex B start codes use four bytes.

To regenerate the stream, use the following FFmpeg settings, then normalize
the Annex B start codes to `00 00 00 01`.

```sh
# Generate pixels locally and keep only the NAL units the regression tests consume.
ffmpeg -f lavfi -i testsrc2=size=128x256:rate=30 -frames:v 5 \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -tune zerolatency -threads 1 \
  -x264-params 'keyint=30:min-keyint=30:scenecut=0:slices=1' \
  -bsf:v 'filter_units=pass_types=1|5|7|8' -f h264 sample.h264
```
