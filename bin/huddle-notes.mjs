#!/usr/bin/env node
// Turn a call transcript into notes: a short recap, your next steps, what the
// others took on, and whether it needs your attention.
//
//     node bin/huddle-notes.mjs ~/Movies/huddles/transcripts/huddle-2026-10-07-1203.txt
//     node bin/huddle-notes.mjs --pending        # every transcript without notes, every note not in Notion yet
//     node bin/huddle-notes.mjs <file> --force   # summarize again (does not refile a page already in Notion)
//
// record-huddle.sh runs it after transcribe-tracks.sh, so nobody has to.
//
// The summary runs on this Mac through `claude -p` (Claude Code, inside your
// plan, no API key). Notes land next to the recording in <HR_DIR>/notes as .md
// and .json. Everything else is optional, set in ~/.config/huddle-recorder/config:
//
//   HR_NAME             whose notes these are ("your next steps" means theirs)
//   HR_NOTES_LANGUAGE   English (default) or Portuguese
//   NOTION_API_KEY +    also file each call as a page in a Notion database with
//   HR_NOTION_DB        the Huddles schema (see README)
//   TWENTY_API_KEY +    calendar context from a Twenty CRM: who was invited to
//   HR_TWENTY_URL +     an overlapping meeting (HR_EMAILS = your own addresses)
//   HR_EMAILS
//   HR_PROJECTS_FILE    a markdown table of projects to tag calls with
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const env = { ...readEnv(join(homedir(), ".config/huddle-recorder/config")), ...process.env };
const HUDDLES = env.HR_DIR || join(homedir(), "Movies/huddles");
const TRANSCRIPTS = join(HUDDLES, "transcripts");
const NOTES = join(HUDDLES, "notes");
const NAME = env.HR_NAME || "the person recording";
const FIRST = NAME.split(/\s+/)[0];
const LANGUAGE = env.HR_NOTES_LANGUAGE || "English";
const NOTION_DB = env.HR_NOTION_DB || "";
const OWN_EMAILS = (env.HR_EMAILS || "").split(",").map((s) => s.trim()).filter(Boolean);
const TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
const MIN_MINUTES = 2;
const MIN_WORDS = 150;

// KEY=value lines, quotes optional, ~ and $HOME expanded. The same file the
// shell scripts source.
function readEnv(path) {
  if (!existsSync(path)) return {};
  const out = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (!m) continue;
    out[m[1]] = m[2].trim().replace(/^["']|["']$/g, "").replace(/^~(?=\/|$)/, homedir()).replace(/\$\{?HOME\}?/g, homedir());
  }
  return out;
}

function notify(title, text) {
  const q = (s) => JSON.stringify(String(s).slice(0, 200));
  spawnSync("osascript", ["-e", `display notification ${q(text)} with title ${q(title)}`]);
}

// ---------------------------------------------------------------- transcript

// "12:03  You:  text" or "1:02:03  Them: text", written by transcribe-tracks.sh.
function readTranscript(path) {
  const cues = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^(\d+):(\d{2})(?::(\d{2}))?\s+(You|Them):\s*(.*)$/);
    if (!m) continue;
    const [, a, b, c, who, text] = m;
    const sec = c === undefined ? +a * 60 + +b : +a * 3600 + +b * 60 + +c;
    if (text.trim()) cues.push({ sec, who, text: text.trim() });
  }
  return cues.length ? cues : readVtt(path.replace(/\.txt$/, ".vtt"));
}

// A single-track recording goes through transcribe.sh, whose .txt has no
// timestamps; its .vtt has them.
function readVtt(path) {
  if (!existsSync(path)) return [];
  const cues = [];
  for (const chunk of readFileSync(path, "utf8").split("\n\n")) {
    const m = chunk.match(/(\d{2}):(\d{2}):(\d{2})\.\d{3} -->[^\n]*\n([\s\S]+)/);
    const text = m && m[4].replace(/\s+/g, " ").trim();
    if (text && text !== cues.at(-1)?.text) cues.push({ sec: +m[1] * 3600 + +m[2] * 60 + +m[3], who: "Call", text });
  }
  return cues;
}

const clock = (sec) => `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}`;

// huddle-2026-10-07-1203 → local start time.
function startOf(name) {
  const m = name.match(/(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/);
  return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) : null;
}

function recordingSeconds(name, cues) {
  for (const ext of ["mkv", "mp4", "mov"]) {
    const file = join(HUDDLES, `${name}.${ext}`);
    if (!existsSync(file)) continue;
    const r = spawnSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file], { encoding: "utf8" });
    const s = parseFloat(r.stdout);
    if (s > 0) return Math.round(s);
  }
  return cues.length ? cues[cues.length - 1].sec : 0;
}

// Local ISO with offset, so Notion shows the time in your own time zone.
function localIso(d) {
  const off = -d.getTimezoneOffset();
  const pad = (n) => String(Math.abs(n)).padStart(2, "0");
  const ymd = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  return `${ymd}T${pad(d.getHours())}:${pad(d.getMinutes())}:00${off >= 0 ? "+" : "-"}${pad(Math.trunc(off / 60))}:${pad(off % 60)}`;
}

// ---------------------------------------------------------------- context

// Calendar events that overlap the call, with who was invited. Huddles are mostly
// ad hoc, so an empty list is normal, and an overlap can still be a coincidence.
async function calendarContext(start, end) {
  const key = env.TWENTY_API_KEY;
  if (!key || !env.HR_TWENTY_URL) return [];
  const get = async (path, params) => {
    const url = new URL(`${env.HR_TWENTY_URL}/rest/${path}`);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    const res = await fetch(url, { headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(20000) });
    if (!res.ok) throw new Error(`Twenty ${path}: ${res.status}`);
    return (await res.json()).data?.[path] || [];
  };
  try {
    const events = (await get("calendarEvents", {
      filter: `startsAt[lte]:"${end.toISOString()}",endsAt[gte]:"${start.toISOString()}"`,
      limit: "30",
    })).filter((e) => !e.isCanceled && !e.isFullDay);
    const callMin = (end - start) / 60000;
    const hits = events.map((e) => {
      const s = new Date(e.startsAt), f = new Date(e.endsAt);
      const overlap = (Math.min(f, end) - Math.max(s, start)) / 60000;
      return { id: e.id, start: s, end: f, overlap: Math.round(overlap), length: (f - s) / 60000 };
    }).filter((e) => e.length <= 180 && e.overlap >= Math.min(10, callMin * 0.3));
    if (!hits.length) return [];
    const people = await get("calendarEventParticipants", {
      filter: `calendarEventId[in]:[${hits.map((h) => `"${h.id}"`).join(",")}]`,
      limit: "200",
    });
    // An event with nobody else on it is a focus block, not this call.
    return hits.map((h) => ({
      ...h,
      participants: [...new Set(people.filter((p) => p.calendarEventId === h.id).map((p) => p.handle).filter((x) => x && !OWN_EMAILS.includes(x)))],
    })).filter((h) => h.participants.length);
  } catch (err) {
    console.error(`calendar skipped: ${err.message}`);
    return [];
  }
}

// Projects from a markdown table ("| P1 | Name | What it is |"), so a call can be
// tagged with the ones it touches. None configured, no tags.
function projects() {
  if (!env.HR_PROJECTS_FILE) return [];
  try {
    return readFileSync(env.HR_PROJECTS_FILE, "utf8").split("\n")
      .map((l) => l.match(/^\| P\d+ \| ([^|]+?) \| ([^|]+?) \|/))
      .filter(Boolean)
      .map((m) => ({ name: m[1].trim().replace(/ without a designer$/, ""), what: m[2].trim() }));
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------- summary

const SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    summary: { type: "string" },
    recap: { type: "array", items: { type: "string" } },
    decisions: { type: "array", items: { type: "string" } },
    my_next_steps: {
      type: "array",
      items: {
        type: "object",
        properties: { step: { type: "string" }, due: { type: ["string", "null"] }, at: { type: "string" } },
        required: ["step", "due", "at"],
      },
    },
    others_next_steps: {
      type: "array",
      items: {
        type: "object",
        properties: { who: { type: "string" }, step: { type: "string" }, at: { type: "string" } },
        required: ["who", "step", "at"],
      },
    },
    open_questions: { type: "array", items: { type: "string" } },
    attention: { type: "string", enum: ["needs_attention", "fyi", "skip"] },
    attention_reason: { type: "string" },
    participants: { type: "array", items: { type: "string" } },
    projects: { type: "array", items: { type: "string" } },
    language: { type: "string", enum: ["PT", "EN", "Mixed"] },
  },
  required: ["title", "summary", "recap", "decisions", "my_next_steps", "others_next_steps", "open_questions",
    "attention", "attention_reason", "participants", "projects", "language"],
};

const SYSTEM = `You turn a recorded work call into notes for ${NAME}, who works at wxrks (formerly Bureau Works), a translation and localization software company. Gabriel Fairman is the founder and CEO. Write plain ${LANGUAGE} with short sentences, whatever language the call was in. Quote the original words only when the exact words matter.

The transcript has two audio tracks. "You" is ${FIRST}'s microphone and "Them" is the call audio. When ${FIRST} is on speakers the mic also hears the others, so many lines marked "You" are someone else talking. Work out who says what from the content: names used in the call, who promises what to whom. Never invent a name; write "the other person" when you cannot tell.

Speech-to-text mangles proper nouns: wxrks comes out as "Works" or "Bureau", Slator as "Isleitor", LocWorld as "Locke", Snov as "Snow". Fix the obvious ones and keep the rest as heard.

Fields:
- title: what the call was about, 3 to 7 words, sentence case. No date, no "huddle", no "call".
- summary: two sentences at most.
- recap: up to 7 bullets in call order, one fact or decision each, 25 words at most.
- decisions: only what was agreed, not ideas floated. Empty if none.
- my_next_steps: what ${FIRST} said they would do, or was asked to do and accepted. Write each as an instruction to them: start with a verb, say "your", never their name. 12 words at most. due: YYYY-MM-DD only if a day was said (resolve "Friday" against the call date), else null. at: the M:SS where it was said.
- others_next_steps: the same for everyone else, with who.
- open_questions: what was left unresolved and who should answer, one line each.
- attention: "needs_attention" only when ${FIRST} owns at least one next step or a decision waits on them. "fyi" when it is useful context with nothing for them to do, even if a client risk or a deadline came up. "skip" when it is a test, silence, or small talk only.
- attention_reason: one line, why.
- participants: first names of the people who spoke, ${FIRST} included, plus calendar participants that clearly fit.
- projects: names from the project list that the call clearly touches, spelled exactly as listed. Empty if none.
- language: the language spoken in the call, PT, EN or Mixed.`;

function summarize(name, start, seconds, cues, calendar) {
  const list = projects();
  const lines = [
    `Call recorded ${start.toDateString()} at ${start.toTimeString().slice(0, 5)} (${TZ}), ${Math.round(seconds / 60)} minutes.`,
    "",
    "Calendar events overlapping the recording (may be unrelated, titles hidden):",
    ...(calendar.length
      ? calendar.map((c) => `- ${c.start.toTimeString().slice(0, 5)} to ${c.end.toTimeString().slice(0, 5)}, overlaps ${c.overlap} min, invited: ${c.participants.join(", ") || "nobody else"}`)
      : ["- none"]),
    "",
    "Project list:",
    ...(list.length ? list.map((p) => `- ${p.name}: ${p.what}`) : ["- none"]),
    "",
    "Transcript:",
    ...cues.map((c) => `${clock(c.sec)}  ${c.who}: ${c.text}`),
  ];
  const r = spawnSync("claude", [
    "-p", "Write the notes for the call on stdin.",
    "--model", "sonnet",
    "--system-prompt", SYSTEM,
    "--tools", "",
    "--no-session-persistence",
    "--output-format", "json",
    "--json-schema", JSON.stringify(SCHEMA),
  ], { input: lines.join("\n"), encoding: "utf8", cwd: HUDDLES, timeout: 15 * 60 * 1000, maxBuffer: 64 * 1024 * 1024 });
  if (r.error?.code === "ENOENT") throw new Error("Claude Code (`claude`) is not installed on this Mac");
  if (r.status !== 0) throw new Error(`claude -p failed (${r.status}): ${(r.stderr || r.stdout || "").slice(0, 500)}`);
  const out = JSON.parse(r.stdout);
  if (out.is_error || !out.structured_output) throw new Error(`claude -p returned no notes: ${String(out.result).slice(0, 500)}`);
  return out.structured_output;
}

// ---------------------------------------------------------------- local notes

function markdown(n) {
  const list = (xs, f = (x) => x) => (xs.length ? xs.map((x) => `- ${f(x)}`).join("\n") : "- None");
  return [
    `# ${n.title}`,
    "",
    `${n.when_label} · ${n.minutes} min · ${n.with || "participants unknown"} · ${n.attention}: ${n.attention_reason}`,
    "",
    n.summary,
    "",
    "## Your next steps",
    list(n.my_next_steps, (s) => `[ ] ${s.step}${s.due ? ` (by ${s.due})` : ""} · ${s.at}`),
    "",
    "## Recap",
    list(n.recap),
    "",
    "## Decisions",
    list(n.decisions),
    "",
    "## Others' next steps",
    list(n.others_next_steps, (s) => `${s.who}: ${s.step} · ${s.at}`),
    "",
    "## Open questions",
    list(n.open_questions),
    "",
    `Transcript: ${n.transcript}`,
    n.notion_url ? `Notion: ${n.notion_url}` : "",
    "",
  ].join("\n");
}

function save(n) {
  writeFileSync(join(NOTES, `${n.name}.json`), JSON.stringify(n, null, 2));
  if (!n.skipped) writeFileSync(join(NOTES, `${n.name}.md`), markdown(n));
}

// ---------------------------------------------------------------- Notion

async function notion(path, method, body) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const res = await fetch(`https://api.notion.com/v1${path}`, {
      method,
      headers: { Authorization: `Bearer ${env.NOTION_API_KEY}`, "Notion-Version": "2022-06-28", "Content-Type": "application/json" },
      body: body && JSON.stringify(body),
      signal: AbortSignal.timeout(30000),
    });
    if (res.status === 429 || res.status >= 500) {
      await new Promise((r) => setTimeout(r, 1000 * (+res.headers.get("retry-after") || 2 ** attempt)));
      continue;
    }
    const data = await res.json();
    if (!res.ok) throw new Error(`Notion ${method} ${path}: ${res.status} ${data.message || ""}`);
    return data;
  }
  throw new Error(`Notion ${method} ${path}: still rate limited`);
}

const rt = (s) => [{ type: "text", text: { content: String(s).slice(0, 2000) } }];
const block = (type, text, extra = {}) => ({ object: "block", type, [type]: { rich_text: rt(text), ...extra } });
const bullets = (xs, f = (x) => x) => (xs.length ? xs.map((x) => block("bulleted_list_item", f(x))) : [block("paragraph", "None.")]);
const ATTENTION = { needs_attention: "Needs attention", fyi: "FYI" };

function stepsText(n) {
  return n.my_next_steps.map((s) => `• ${s.step}${s.due ? ` (by ${s.due})` : ""}`).join("\n");
}

// The transcript as paragraphs of whole lines, each under Notion's 2,000-character cap.
function transcriptBlocks(cues) {
  const blocks = [block("paragraph", "You = your mic. Them = the call audio. On speakers your mic hears both sides, so names are worked out from the talk, not the labels.", { color: "gray" })];
  let buf = "";
  for (const c of cues) {
    const line = `${clock(c.sec)}  ${c.who}: ${c.text}`.slice(0, 1900);
    if (buf && buf.length + line.length + 1 > 1900) {
      blocks.push(block("paragraph", buf));
      buf = "";
    }
    buf = buf ? `${buf}\n${line}` : line;
  }
  if (buf) blocks.push(block("paragraph", buf));
  return blocks;
}

async function appendAll(parent, blocks) {
  let last;
  for (let i = 0; i < blocks.length; i += 100) last = await notion(`/blocks/${parent}/children`, "PATCH", { children: blocks.slice(i, i + 100) });
  return last;
}

async function file(n, cues) {
  if (!n.notion_page_id) {
    const page = await notion("/pages", "POST", {
      parent: { database_id: NOTION_DB },
      icon: { type: "emoji", emoji: "🎧" },
      properties: {
        Name: { title: rt(n.title) },
        When: { date: { start: n.start, end: n.end } },
        Attention: { select: { name: ATTENTION[n.attention] } },
        "Your next steps": { rich_text: rt(stepsText(n)) },
        With: { rich_text: rt(n.with) },
        Projects: { multi_select: n.projects.map((name) => ({ name: name.replace(/,/g, "") })) },
        Minutes: { number: n.minutes },
        Language: { select: { name: n.language } },
        Recording: { rich_text: rt(n.name) },
      },
      children: [
        block("callout", `${n.summary}\n\n${ATTENTION[n.attention]}: ${n.attention_reason}`, { icon: { type: "emoji", emoji: n.attention === "needs_attention" ? "🔴" : "💬" } }),
        block("heading_2", "Your next steps"),
        ...(n.my_next_steps.length
          ? n.my_next_steps.map((s) => block("to_do", `${s.step}${s.due ? ` (by ${s.due})` : ""} · ${s.at}`, { checked: false }))
          : [block("paragraph", "Nothing for you.")]),
        block("heading_2", "Recap"),
        ...bullets(n.recap),
        block("heading_2", "Decisions"),
        ...bullets(n.decisions),
        block("heading_2", "Others' next steps"),
        ...bullets(n.others_next_steps, (s) => `${s.who}: ${s.step} · ${s.at}`),
        block("heading_2", "Open questions"),
        ...bullets(n.open_questions),
      ],
    });
    n.notion_page_id = page.id;
    n.notion_url = page.url;
    save(n);
  }
  // A page filed by hand carries no transcript; this adds the readable copy.
  if (!n.transcript_inline) {
    const res = await appendAll(n.notion_page_id, [{
      object: "block", type: "heading_2",
      heading_2: { rich_text: rt(`Transcript (${n.minutes} min)`), is_toggleable: true },
    }]);
    await appendAll(res.results[0].id, transcriptBlocks(cues));
    n.transcript_inline = true;
    save(n);
  }
}

// ---------------------------------------------------------------- main

async function process1(transcript, { force = false } = {}) {
  const name = basename(transcript).replace(/\.txt$/, "");
  const notesPath = join(NOTES, `${name}.json`);
  const cues = readTranscript(transcript);
  let n = existsSync(notesPath) ? JSON.parse(readFileSync(notesPath, "utf8")) : null;
  if (n?.skipped && !force) return n;

  const fresh = !n || force;
  if (fresh) {
    const start = startOf(name);
    if (!start) throw new Error(`${name}: no date and time in the file name`);
    const seconds = recordingSeconds(name, cues);
    const words = cues.reduce((sum, c) => sum + c.text.split(/\s+/).length, 0);
    const keep = n?.notion_page_id ? { notion_page_id: n.notion_page_id, notion_url: n.notion_url, transcript_inline: n.transcript_inline } : {};
    if (seconds < MIN_MINUTES * 60 || words < MIN_WORDS) {
      n = { name, skipped: `too short (${Math.round(seconds / 60)} min, ${words} words)` };
      save(n);
      console.log(`${name}: ${n.skipped}, no notes`);
      return n;
    }
    const end = new Date(start.getTime() + seconds * 1000);
    const calendar = await calendarContext(start, end);
    console.log(`${name}: summarizing ${cues.length} lines, ${Math.round(seconds / 60)} min, ${calendar.length} calendar overlap(s)`);
    const s = summarize(name, start, seconds, cues, calendar);
    const invited = [...new Set(calendar.flatMap((c) => c.participants))];
    const me = new RegExp(`^${FIRST.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`, "i");
    n = {
      name, ...s, ...keep,
      start: localIso(start), end: localIso(end),
      when_label: `${start.toDateString()} ${start.toTimeString().slice(0, 5)}`,
      minutes: Math.round(seconds / 60),
      with: [s.participants.filter((p) => !me.test(p)).join(", "), invited.length ? `calendar: ${invited.join(", ")}` : ""].filter(Boolean).join(" · "),
      calendar: calendar.map((c) => ({ start: c.start, end: c.end, overlap: c.overlap, participants: c.participants })),
      transcript,
      summarized_at: new Date().toISOString(),
    };
    // The model writes project names loosely ("Ads: Better paid campaigns"); keep the listed ones only.
    const listed = projects().map((p) => p.name);
    n.projects = [...new Set(s.projects.map((x) => listed.find((l) => x.toLowerCase().startsWith(l.toLowerCase()))).filter(Boolean))];
    // A flag with no next step to show would point at nothing.
    if (s.attention === "needs_attention" && !s.my_next_steps.length) n.attention = "fyi";
    if (s.attention === "skip") n.skipped = `nothing to note: ${s.attention_reason}`;
    save(n);
    if (n.skipped) {
      console.log(`${name}: ${n.skipped}`);
      return n;
    }
  }

  if (!env.NOTION_API_KEY || !NOTION_DB) {
    console.log(`${name}: notes in ${join(NOTES, `${name}.md`)}`);
    if (fresh) notify(`Call notes: ${n.title}`, `${n.my_next_steps.length} next step(s) for you. Saved in ${basename(HUDDLES)}/notes.`);
    return n;
  }
  const isNew = !n.notion_page_id;
  await file(n, cues);
  console.log(`${name}: ${n.notion_url}`);
  if (isNew) notify(`Call notes: ${n.title}`, `${n.my_next_steps.length} next step(s) for you. Filed in Notion.`);
  return n;
}

const args = process.argv.slice(2);
const force = args.includes("--force");
mkdirSync(NOTES, { recursive: true });
const targets = args.includes("--pending")
  ? readdirSync(TRANSCRIPTS).filter((f) => /^huddle-.*\d\.txt$/.test(f)).sort().map((f) => join(TRANSCRIPTS, f))
  : args.filter((a) => !a.startsWith("--"));
if (!targets.length) {
  console.error("usage: huddle-notes.mjs <transcript.txt>... | --pending [--force]");
  process.exit(64);
}
let failed = 0;
for (const t of targets) {
  try {
    await process1(t, { force });
  } catch (err) {
    failed++;
    console.error(`${basename(t)}: ${err.message}`);
    notify("Call notes failed", `${basename(t)}: ${err.message}`);
  }
}
process.exit(failed ? 1 : 0);
