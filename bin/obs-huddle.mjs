#!/usr/bin/env node
// Drive OBS recording over its built-in websocket (obs-websocket 5).
//
//     node bin/obs-huddle.mjs status|start|stop|toggle|ensure
//
// Prints one JSON line. Used by bin/record-huddle.sh — the thing behind the
// "Record Huddle" button. Talking to OBS over the socket (instead of quitting
// the app to stop a recording) is what lets one button toggle, and what gives us
// the finished file's path back from StopRecord.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const CONFIG = `${homedir()}/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json`;
const COLLECTION = "Huddle";
const PROFILE = "Huddle";

const cfg = JSON.parse(readFileSync(CONFIG, "utf8"));
if (!cfg.server_enabled) throw new Error("obs-websocket is disabled in OBS (Tools > WebSocket Server Settings)");

const sha = (s) => createHash("sha256").update(s).digest("base64");

function connect() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${cfg.server_port || 4455}`);
    const pending = new Map();
    let n = 0;

    ws.onerror = () => reject(new Error("OBS is not listening — is it running?"));
    ws.onclose = () => pending.forEach(({ reject }) => reject(new Error("OBS closed the connection")));

    ws.onmessage = (ev) => {
      const { op, d } = JSON.parse(ev.data);
      if (op === 0) {
        // Hello. Auth only when the server asked for it.
        const auth = d.authentication
          ? sha(sha(cfg.server_password + d.authentication.salt) + d.authentication.challenge)
          : undefined;
        ws.send(JSON.stringify({ op: 1, d: { rpcVersion: 1, eventSubscriptions: 0, ...(auth && { authentication: auth }) } }));
      } else if (op === 2) {
        resolve({
          close: () => ws.close(),
          request: (requestType, requestData = {}) =>
            new Promise((res, rej) => {
              const requestId = String(++n);
              pending.set(requestId, { resolve: res, reject: rej });
              ws.send(JSON.stringify({ op: 6, d: { requestType, requestId, requestData } }));
            }),
        });
      } else if (op === 7) {
        const p = pending.get(d.requestId);
        if (!p) return;
        pending.delete(d.requestId);
        d.requestStatus.result
          ? p.resolve(d.responseData || {})
          : p.reject(new Error(`${d.requestType}: ${d.requestStatus.comment || d.requestStatus.code}`));
      }
    };
  });
}

// OBS only applies --collection / --profile at launch, so a session that was
// already open on something else gets switched here instead.
async function ensure(obs) {
  const switched = [];
  const collections = await obs.request("GetSceneCollectionList");
  if (collections.currentSceneCollectionName !== COLLECTION) {
    if (!collections.sceneCollections.includes(COLLECTION)) throw new Error(`no "${COLLECTION}" scene collection in OBS`);
    await obs.request("SetCurrentSceneCollection", { sceneCollectionName: COLLECTION });
    switched.push("collection");
  }
  const profiles = await obs.request("GetProfileList");
  if (profiles.currentProfileName !== PROFILE) {
    if (!profiles.profiles.includes(PROFILE)) throw new Error(`no "${PROFILE}" profile in OBS`);
    await obs.request("SetCurrentProfile", { profileName: PROFILE });
    switched.push("profile");
  }
  // Switching either one reloads OBS's outputs; give it a beat before recording.
  if (switched.length) await new Promise((r) => setTimeout(r, 1500));
  return switched;
}

const command = process.argv[2] || "status";
const obs = await connect();
let out = {};

try {
  if (command === "status") {
    const [rec, col] = await Promise.all([obs.request("GetRecordStatus"), obs.request("GetSceneCollectionList")]);
    out = { recording: rec.outputActive, timecode: rec.outputTimecode, collection: col.currentSceneCollectionName };
  } else if (command === "ensure") {
    out = { switched: await ensure(obs) };
  } else if (command === "start" || command === "stop" || command === "toggle") {
    const { outputActive } = await obs.request("GetRecordStatus");
    const stopping = command === "stop" || (command === "toggle" && outputActive);
    if (stopping) {
      if (!outputActive) out = { action: "idle" };
      else out = { action: "stopped", path: (await obs.request("StopRecord")).outputPath };
    } else if (outputActive) {
      out = { action: "already-recording" };
    } else {
      await ensure(obs);
      await obs.request("StartRecord");
      out = { action: "started" };
    }
  } else if (command === "request") {
    // Escape hatch for anything else OBS can do, e.g.
    //   obs-huddle.mjs request SetInputMute '{"inputName":"Mic/Aux","inputMuted":true}'
    out = await obs.request(process.argv[3], JSON.parse(process.argv[4] || "{}"));
  } else {
    throw new Error(`unknown command: ${command}`);
  }
  console.log(JSON.stringify(out));
} finally {
  obs.close();
}
