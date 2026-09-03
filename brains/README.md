# brains/

Each folder here is a **specialist agent** — one subject, one team, one client.

```
brains/cs61a/brain.json     persona + kind (lecture | meeting)
brains/cs61a/inbox/         drop recordings here
brains/cs61a/recaps/        transcripts + analysis (RAG corpus)
brains/cs61a/notes/         markdown copies
```

```bash
./catchup brain new cs61a --lecture
./catchup into cs61a ~/Downloads/week3.mp4
./catchup ask cs61a explain environment diagrams
```

Cursor / Claude Desktop can talk to the same brains via `./catchup mcp`.
