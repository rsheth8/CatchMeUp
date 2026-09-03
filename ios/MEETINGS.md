# Meeting workspace

## User workflow

1. Open Record in Meeting mode and choose **Agenda, materials & preparation**.
2. Add a title, agenda, PDFs, PowerPoint files, or scanned pages. Preparation is
   saved as a draft in Recaps, even if recording is cancelled. Reopen the draft
   and choose **Record this meeting** to continue without making another copy.
3. Meeting recaps have **Summary**, **Decisions**, **Follow-ups**, and **Materials**.
   Existing meetings gain the workspace without losing their notes or completion checks.
4. Use **Refresh meeting insights** on an existing recap or after adding documents.
   New non-demo recordings run the analysis after their transcript recap completes.
5. Review generated follow-ups, confirm their owner/date/status, and explicitly
   choose **Add to Reminders**. Later exports update the same reminder.
6. Group recurring meetings in a Brain to see preparation briefs, a dated decision
   timeline, and ask for a comparison of decisions across meetings.

## Data and safety

- `Recording.meeting` is optional for backwards compatibility. User-reviewed
  tasks and outcomes live separately from generated recap text.
- Material ownership can be standalone or Brain-scoped. Existing attachments can
  be linked to a meeting without duplicating their original files.
- Task IDs, completion, user edits, confirmed dates, and exported reminder IDs
  survive regeneration. Async generation merges in newer user edits before saving.
- Generated owners/deadlines are suggestions requiring review. Relative deadlines
  remain verbatim text until a person chooses a calendar date.
- Analysis requires a matching transcript quote. Playback timestamps are accepted
  only when the quoted line contains that timestamp. Proposal/decision/blocker/
  question classifications remain reviewable, not treated as verified truth.
- Document context is separately labelled and links to an actual document page.
  Documents are not inserted into the transcript or represented as spoken agreement.
- Long transcripts and document pages are processed in bounded windows/excerpts.
  Document coverage is selective, not a claim of exhaustive visual understanding.
- The default phone engine uses Foundation Models guided generation; configured
  API engines receive relevant transcript/document excerpts. Demo does not invoke AI.
- Local functionality does not require iCloud or an app-hosted backend. Document
  originals remain in local app storage; this work does not implement document sync.
- No reminders, messages, invitations, or calendar events are created in the
  background. Reminders export requires review, a tap, and OS permission.
- Recurring-meeting history is limited to the same Brain. A newer statement does
  not automatically supersede a prior decision; users review those changes.
- Meetings no longer trigger the lecture prequestion sheet. Meeting documents
  imported with meeting usage do not automatically mint study cards.

## Validation

`MeetingWorkspaceTests` covers legacy migration, standalone materials, quote and
timestamp validation, source-page validation, task identity/edit preservation,
budget limits, scoped history, completed-task suppression, safe reminder review,
and the complete analysis path using a deterministic test engine.

Device acceptance still includes live Foundation Models generation, camera scans,
Reminders permission denial/grant/re-export, large text sizes, and testing with
real meeting audio and representative documents. A simulator build and stubbed
model tests cannot validate transcription or AI output quality on their own.
