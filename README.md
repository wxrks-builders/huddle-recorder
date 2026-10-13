# Huddle Rec

One button that records a call, transcribes it on your Mac, and writes notes:
a short recap, your next steps, and what everyone else agreed to do.

It works with any call that makes sound on your Mac: Slack huddles (which have
no recording of their own), Google Meet, Zoom, Teams, or a video playing.

Mac only for now.

## The one rule

**Say at the start of the call that you are recording.** Everyone on the call
should know.

## Install (about 10 minutes, most of it downloading)

You need [Homebrew](https://brew.sh). Then, in Terminal:

```sh
git clone https://github.com/wxrks-builders/huddle-recorder.git ~/huddle-recorder
~/huddle-recorder/install.sh
```

If GitHub says the repo is not found, ask Rodrigo for access.

The installer asks your name, and optionally a team folder for the notes. At
the end it opens OBS once. When macOS asks, allow **Microphone** and **Screen &
System Audio Recording**. The second one is how it hears the other people on
the call. It does not record your screen.

For notes, you also need [Claude Code](https://claude.com/claude-code) signed
in on your Mac. Without it you still get the full transcript.

## Use it

**Huddle Rec** is the black square with a white ring in your Dock (and a dot in
the menu bar).

1. Click it. The dot turns red and a red **REC** badge appears at the top right.
2. Click it again when the call ends.
3. A few minutes later you get a notification: the transcript is ready, then
   the notes.

Right-click the button for **Open transcripts** and **Open recordings**.

## Where things go

| What | Where |
| --- | --- |
| Recordings | `~/Movies/huddles` |
| Transcripts | `~/Movies/huddles/transcripts` |
| Notes | `~/Movies/huddles/notes` |
| Settings | `~/.config/huddle-recorder/config` |

The transcript has two sides: **You** is your microphone, **Them** is the call
audio. If you are on speakers instead of headphones, your mic hears everyone,
so some "You" lines are other people.

## Privacy

- Recording and transcription run on your Mac. The recording never leaves it.
- To write notes, the transcript text goes to Claude through your own Claude
  Code account. Turn that off with `HR_NOTES="off"` in your settings.
- Nothing is shared unless you set a team folder. Then only the notes are
  copied there. Full transcripts are copied only if you also set
  `HR_SHARE_TRANSCRIPTS=1`. Transcripts are everyone on the call talking, so
  think before you share them.

## Settings

Open `~/.config/huddle-recorder/config` in any text editor:

| Setting | What it does |
| --- | --- |
| `HR_NAME` | Your name. The notes are written for you. |
| `HR_NOTES_LANGUAGE` | `English` or `Portuguese`. |
| `HR_NOTES` | `auto`, or `off` for transcripts only. |
| `HR_SHARE_DIR` | A folder that gets a copy of each call's notes. |
| `HR_SHARE_TRANSCRIPTS` | `1` to copy full transcripts there too. |
| `HR_DIR` | Where everything is saved. If you change it, run `install.sh --force`. |

Optional, for filing each call in Notion: set `NOTION_API_KEY` (an internal
integration with access to the database) and `HR_NOTION_DB` (the database id).
The database needs these properties: Name (title), When (date), Attention
(select: Needs attention, FYI, Done), Your next steps (text), With (text),
Projects (multi-select), Minutes (number), Language (select: PT, EN, Mixed),
Recording (text).

## If something goes wrong

- **Nothing happens when I click.** Open OBS once by hand, check it starts,
  quit it, and try again.
- **The transcript is empty or only has one side.** Check the permissions in
  System Settings > Privacy & Security: OBS needs Microphone and Screen &
  System Audio Recording.
- **A line repeats over and over.** The transcriber does that on long
  silences. Nobody said it twice.
- **Notes did not come.** Check that `claude` works in Terminal. The log is
  `~/Movies/huddles/.record-huddle.log`.
- **Notes for an old call.** `node ~/huddle-recorder/bin/huddle-notes.mjs --pending`
  writes notes for every transcript that has none.

## Update or remove

Update: `cd ~/huddle-recorder && git pull && ./install.sh`

Remove the button: `~/huddle-recorder/uninstall.sh`. It keeps your recordings
and says how to remove the rest.

## How it works

OBS records two audio tracks: the call audio through macOS ScreenCaptureKit,
and your mic. The button drives OBS over its local remote control, so OBS
stays hidden. When you stop, `bin/transcribe-tracks.sh` runs whisper.cpp
(large-v3-turbo) on each track and merges them by time. `bin/huddle-notes.mjs`
then asks Claude Code for the notes. A one-hour call transcribes in a few
minutes on Apple Silicon.

```
app/        the button (Swift) and its build script
bin/        record, transcribe, notes
obs/        the OBS scene collection and profile the installer adds
install.sh  sets it all up; safe to run again
```
