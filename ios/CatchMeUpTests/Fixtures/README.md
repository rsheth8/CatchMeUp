# Test fixtures

`two-speakers.m4a` — 17 seconds of a fictional two-person standup, built locally
with macOS `say` (Samantha and Daniel, alternating four turns) and concatenated
with FFmpeg to 16 kHz mono. No real voices, no real meeting.

It exists because diarization cannot be checked against single-speaker audio:
every showcase clip is one narrator, so "found one speaker" proves nothing about
whether the speaker pipeline runs at all. This file is the smallest thing that
distinguishes working diarization from a no-op.

Rebuild it with:

```bash
say -v Samantha -r 170 -o a.aiff "Right, let's start with the billing migration. Where did we land on the cutover date?"
say -v Daniel   -r 170 -o b.aiff "We landed on the fourteenth. The staging run finished clean, so I'm comfortable with that."
say -v Samantha -r 170 -o c.aiff "Good. Then let's write it down as decided and move on to the support rota."
say -v Daniel   -r 170 -o d.aiff "Agreed. I'll take the first week and hand over on the Friday."
ffmpeg -y -i a.aiff -i b.aiff -i c.aiff -i d.aiff \
  -filter_complex "[0][1][2][3]concat=n=4:v=0:a=1[a]" -map "[a]" \
  -ar 16000 -ac 1 -c:a aac -b:a 32k two-speakers.m4a
```
