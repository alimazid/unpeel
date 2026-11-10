/**
 * Unpeel lifecycle reporter for OMP.
 *
 * Installed by Unpeel's `omp` runtime integration into the OMP agent
 * directory (`<agent dir>/extensions/unpeel-lifecycle.ts`), where OMP's
 * native extension discovery loads it. OMP has no shell-hook configuration:
 * its extension event bus is the provider's own lifecycle mechanism, so this
 * module is the hook script for this runtime.
 *
 * Contract (see runtimes/README.md, "Package rules"):
 * - inert outside a hosted Unpeel Session;
 * - carries the numeric `unpeel_runtime_generation`;
 * - reports to the direct hook port and to every port in the registry;
 * - forwards only the provider conversation id and transcript path;
 * - durably seeds `last-hook-event.json` before the event is delivered;
 * - before either, asks the installing Host whether this process speaks for
 *   the Session it names (ADR 0013), and drops the event on a refusal.
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";

const SESSION_ID = (process.env.UNPEEL_SESSION_ID ?? "").trim();
const SESSION_DIR = (process.env.UNPEEL_SESSION_DIR ?? "").trim();
const APP_PORT = (process.env.UNPEEL_APP_PORT ?? "").trim();
const GENERATION = Number.parseInt(process.env.UNPEEL_RUNTIME_GENERATION ?? "", 10);
const UNPEEL_HOME = (process.env.UNPEEL_HOME ?? "").trim() || path.join(process.env.HOME ?? "", ".unpeel");
const PORT_REGISTRY = (process.env.UNPEEL_APP_PORT_REGISTRY_FILE ?? "").trim() || path.join(UNPEEL_HOME, "app-ports");
const TRACE_FILE = (process.env.UNPEEL_HOOK_TRACE_FILE ?? "").trim() || path.join(UNPEEL_HOME, "hooks", "trace.log");

/**
 * The `unpeel-host` that installed this extension, filled in at install
 * (`hook_assets::reporter_module`). Not the Session's exported
 * `UNPEEL_HOST_BIN`: an older Host reads an unknown argument as a launch
 * file. Left as the placeholder (or empty), no check runs.
 */
const IDENTITY_CHECKER = "{{UNPEEL_HOST_BIN}}";
const IDENTITY_CHECK_ARG = "__session_identity__";
/** The checker's exit code for a process that provably is not the Session's. */
const IDENTITY_REFUSED = 3;
const IDENTITY_CHECK_TIMEOUT_MS = 2000;

/** Events the activity reducer accepts as a durable busy/idle/attention edge. */
const RECORDED_EVENTS: Record<string, true> = {
	Start: true,
	UserPromptSubmit: true,
	Stop: true,
	StopFailure: true,
	StopCancelled: true,
	PermissionRequest: true,
};

interface HookPayload {
	hook_event_name: string;
	tool_name?: string;
	session_id?: string;
	transcript_path?: string;
	unpeel_runtime_generation?: number;
}

function portFrom(value: string | undefined): number | undefined {
	if (!value || !/^\d+$/.test(value)) return undefined;
	const port = Number.parseInt(value, 10);
	return port > 0 && port <= 65535 ? port : undefined;
}

/** Every port another Unpeel instance registered, newest file contents read fresh. */
function registryPorts(): number[] {
	const ports: number[] = [];
	try {
		for (const line of fs.readFileSync(PORT_REGISTRY, "utf8").split("\n")) {
			const port = portFrom(line.trim());
			if (port !== undefined && !ports.includes(port)) ports.push(port);
		}
	} catch {
		// A missing or unreadable registry is normal when no app is running.
	}
	return ports;
}

function payloadFor(event: string, extra: Partial<HookPayload> = {}): HookPayload {
	const payload: HookPayload = { hook_event_name: event, ...extra };
	if (Number.isFinite(GENERATION)) payload.unpeel_runtime_generation = GENERATION;
	return payload;
}

/**
 * Why the installing Host refuses this process as its Session's, or
 * undefined when it does not. An inherited `UNPEEL_SESSION_ID` is only a
 * claim (#70): a process that outlives its parent shell is reparented out of
 * the Session's tree and keeps the environment. So the answer is asked for
 * every event and never cached. Only a definite refusal counts; a checker
 * that is missing, fails, times out or cannot tell yet keeps delivery on.
 */
async function identityRefusal(): Promise<string | undefined> {
	if (!path.isAbsolute(IDENTITY_CHECKER)) return undefined;
	const { promise, resolve } = Promise.withResolvers<string | undefined>();
	let output = "";
	const checker = spawn(IDENTITY_CHECKER, [IDENTITY_CHECK_ARG], {
		env: { ...process.env, UNPEEL_SESSION_ID: SESSION_ID, UNPEEL_SESSION_DIR: SESSION_DIR },
		stdio: ["ignore", "pipe", "ignore"],
	});
	const timer = setTimeout(() => {
		checker.kill("SIGKILL");
		resolve(undefined);
	}, IDENTITY_CHECK_TIMEOUT_MS);
	checker.stdout?.on("data", (chunk) => {
		output += chunk;
	});
	checker.on("error", () => {
		clearTimeout(timer);
		resolve(undefined);
	});
	checker.on("close", (code) => {
		clearTimeout(timer);
		resolve(code === IDENTITY_REFUSED ? output.trim().split("\n")[0] || "refused" : undefined);
	});
	return promise;
}

/** The shell reporters' `hook-refused` trace line, local time. */
function traceRefusal(reason: string): void {
	const now = new Date();
	const pad = (value: number) => String(value).padStart(2, "0");
	const stamp =
		`${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ` +
		`${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
	try {
		fs.mkdirSync(path.dirname(TRACE_FILE), { recursive: true });
		fs.appendFileSync(TRACE_FILE, `${stamp} hook-refused session=${SESSION_ID} reason=${reason}\n`, { mode: 0o600 });
	} catch {
		// Tracing is diagnostic only; the event is dropped either way.
	}
}

/** Atomic write into the session directory; never creates it. */
function seedDurableEvent(body: string): void {
	if (!SESSION_DIR) return;
	try {
		const target = path.join(SESSION_DIR, "last-hook-event.json");
		if (!fs.existsSync(SESSION_DIR)) return;
		const temporary = `${target}.${process.pid}.tmp`;
		fs.writeFileSync(temporary, body, { mode: 0o600 });
		fs.renameSync(temporary, target);
	} catch {
		// The session may be torn down mid-turn; delivery still proceeds.
	}
}

/** One bounded loopback POST. Stale registry ports are expected and ignored. */
async function post(port: number, body: string): Promise<void> {
	const { promise, resolve } = Promise.withResolvers<void>();
	const request = http.request(
		{
			host: "127.0.0.1",
			port,
			path: `/hook/${SESSION_ID}`,
			method: "POST",
			headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
			timeout: 1000,
		},
		(response) => {
			response.resume();
			response.on("end", resolve);
			response.on("error", resolve);
		},
	);
	request.on("error", resolve);
	request.on("timeout", () => {
		request.destroy();
		resolve();
	});
	request.end(body);
	await promise;
}

/** Report one lifecycle edge, finishing delivery before the handler returns. */
async function report(event: string, extra: Partial<HookPayload> = {}): Promise<void> {
	const refusal = await identityRefusal();
	if (refusal !== undefined) {
		traceRefusal(refusal);
		return;
	}
	const payload = payloadFor(event, extra);
	const body = JSON.stringify(payload);
	if (RECORDED_EVENTS[event]) seedDurableEvent(body);
	const direct = portFrom(APP_PORT);
	if (direct !== undefined) await post(direct, body);
	const others = registryPorts().filter((port) => port !== direct);
	if (others.length > 0) await Promise.all(others.map((port) => post(port, body)));
}

export default function unpeelLifecycle(pi: ExtensionAPI): void {
	if (!SESSION_ID) return;

	const identity = (ctx: { sessionManager: { getSessionId(): string; getSessionFile(): string | undefined } }) => ({
		session_id: ctx.sessionManager.getSessionId(),
		transcript_path: ctx.sessionManager.getSessionFile(),
	});

	// HookSeen latches provider identity (conversation id + transcript path)
	// without marking the session busy.
	pi.on("session_start", async (_event, ctx) => {
		await report("HookSeen", identity(ctx));
	});

	// A prompt batch is the opening edge of a turn, including steers and
	// follow-ups that omp dequeues while a turn is already live.
	pi.on("before_agent_start", async () => {
		await report("UserPromptSubmit");
	});

	// `willContinue` means omp already scheduled an automatic continuation
	// (retry, empty-stop retry); that turn has not settled.
	pi.on("agent_end", async (event) => {
		if (!event.willContinue) await report("Stop");
	});

	pi.on("tool_approval_requested", async (event) => {
		await report("PermissionRequest", { tool_name: event.toolName });
	});

	// Leaving omp settles whatever latch is open; a dead session must not
	// stay busy in the sidebar.
	pi.on("session_shutdown", async () => {
		await report("Stop");
	});
}
