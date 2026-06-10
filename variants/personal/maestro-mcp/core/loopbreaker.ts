/**
 * Crew loop-breaker / drift detector.
 *
 * Pure / node-builtin-only: consumes caller-supplied crew tool-call/result telemetry and detects
 * within-round repetition before outer idle/max timeouts or maxRounds have to intervene. No
 * filesystem, pi SDK, model, or process imports live here, so the detector stays headlessly
 * unit-testable and can be wired into any subprocess runner that emits Foreman transcript events.
 */

import { createHash } from "node:crypto";

export type LoopToolEvent =
	| { kind: "tool_call"; name: string; args: unknown }
	| { kind: "tool_result"; name: string; ok: boolean; preview: string };

export type LoopSeverity = "soft" | "hard";
export type LoopPattern = "identical_tool_call" | "edit_oscillation" | "repeated_error_signature";

export interface LoopEvidence {
	count: number;
	threshold: number;
	window: number;
	toolName: string;
	argsPreview?: string;
	path?: string;
	contentHash?: string;
	preview?: string;
}

export interface LoopVerdict {
	tripped: boolean;
	severity?: LoopSeverity;
	pattern?: LoopPattern;
	signature?: string;
	/** Human-readable one-line summary suitable for ledger logs and retry prompts. */
	summary?: string;
	evidence?: LoopEvidence;
}

export interface LoopDetectorConfig {
	softThreshold?: number;
	hardThreshold?: number;
	/** Alias for softThreshold, accepted for concise config objects. */
	soft?: number;
	/** Alias for hardThreshold, accepted for concise config objects. */
	hard?: number;
	toolCallWindow?: number;
	errorWindow?: number;
	editOscillationWindow?: number;
	errorPreviewChars?: number;
	/** File-editing tools, e.g. write/edit/Write/Edit or namespaced variants. */
	editToolPattern?: RegExp | string;
}

export interface ResolvedLoopDetectorConfig {
	softThreshold: number;
	hardThreshold: number;
	toolCallWindow: number;
	errorWindow: number;
	editOscillationWindow: number;
	errorPreviewChars: number;
	editToolPattern: RegExp;
}

export interface LoopDetectorSnapshot {
	config: Omit<ResolvedLoopDetectorConfig, "editToolPattern"> & { editToolPattern: string };
	toolCalls: Array<{ signature: string; count: number; toolName: string; summary: string }>;
	errors: Array<{ signature: string; count: number; toolName: string; preview: string }>;
	edits: Array<{ path: string; hashes: string[] }>;
}

export interface LoopDetector {
	observe(event: LoopToolEvent): LoopVerdict;
	snapshot(): LoopDetectorSnapshot;
}

export type LoopBreakerEnv = Record<string, string | undefined>;

export const DEFAULT_LOOP_SOFT_THRESHOLD = 3;
export const DEFAULT_LOOP_HARD_THRESHOLD = 5;

const DEFAULT_TOOL_CALL_WINDOW = 10;
const DEFAULT_ERROR_WINDOW = 10;
const DEFAULT_EDIT_OSCILLATION_WINDOW = 10;
const DEFAULT_ERROR_PREVIEW_CHARS = 200;
const DEFAULT_EDIT_TOOL_PATTERN = /write|edit/i;

const NO_LOOP: LoopVerdict = { tripped: false };

interface ToolCallObservation {
	signature: string;
	toolName: string;
	argsPreview: string;
}

interface ErrorObservation {
	signature: string;
	toolName: string;
	preview: string;
}

interface EditObservation {
	path: string;
	toolName: string;
	contentHash: string;
}

function parsePositiveInteger(value: string | undefined, fallback: number): number {
	if (value == null || value.trim() === "") return fallback;
	const parsed = Number(value);
	return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback;
}

/** Parse FOREMAN_LOOP_SOFT / FOREMAN_LOOP_HARD threshold overrides. */
export function parseLoopBreakerEnv(env: LoopBreakerEnv): Pick<ResolvedLoopDetectorConfig, "softThreshold" | "hardThreshold"> {
	const softThreshold = parsePositiveInteger(env.FOREMAN_LOOP_SOFT, DEFAULT_LOOP_SOFT_THRESHOLD);
	const requestedHard = parsePositiveInteger(env.FOREMAN_LOOP_HARD, DEFAULT_LOOP_HARD_THRESHOLD);
	return { softThreshold, hardThreshold: Math.max(softThreshold, requestedHard) };
}

function asPositiveInteger(value: unknown, fallback: number): number {
	return typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

function resolveConfig(config: LoopDetectorConfig = {}): ResolvedLoopDetectorConfig {
	const softThreshold = asPositiveInteger(config.softThreshold ?? config.soft, DEFAULT_LOOP_SOFT_THRESHOLD);
	const hardThreshold = Math.max(softThreshold, asPositiveInteger(config.hardThreshold ?? config.hard, DEFAULT_LOOP_HARD_THRESHOLD));
	const rawPattern = config.editToolPattern ?? DEFAULT_EDIT_TOOL_PATTERN;
	const editToolPattern = typeof rawPattern === "string" ? new RegExp(rawPattern, "i") : rawPattern;
	return {
		softThreshold,
		hardThreshold,
		toolCallWindow: Math.max(hardThreshold, asPositiveInteger(config.toolCallWindow, DEFAULT_TOOL_CALL_WINDOW)),
		errorWindow: Math.max(hardThreshold, asPositiveInteger(config.errorWindow, DEFAULT_ERROR_WINDOW)),
		editOscillationWindow: Math.max(hardThreshold, asPositiveInteger(config.editOscillationWindow, DEFAULT_EDIT_OSCILLATION_WINDOW)),
		errorPreviewChars: asPositiveInteger(config.errorPreviewChars, DEFAULT_ERROR_PREVIEW_CHARS),
		editToolPattern,
	};
}

function hashString(value: string): string {
	return createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function truncate(value: string, maxChars: number): string {
	const oneLine = value.replace(/\s+/g, " ").trim();
	return oneLine.length > maxChars ? `${oneLine.slice(0, Math.max(0, maxChars - 1))}…` : oneLine;
}

function stableJsonStringify(value: unknown): string {
	const stack = new WeakSet<object>();
	const encode = (v: unknown, inArray = false): string | undefined => {
		if (v === null) return "null";
		if (v === undefined || typeof v === "function" || typeof v === "symbol") return inArray ? "null" : undefined;
		if (typeof v === "string") return JSON.stringify(v);
		if (typeof v === "number") return Number.isFinite(v) ? String(v) : "null";
		if (typeof v === "boolean") return v ? "true" : "false";
		if (typeof v === "bigint") return JSON.stringify(v.toString());
		if (typeof v !== "object") return JSON.stringify(String(v));
		if (stack.has(v)) return JSON.stringify("[Circular]");
		stack.add(v);
		try {
			if (Array.isArray(v)) return `[${v.map((item) => encode(item, true) ?? "null").join(",")}]`;
			const record = v as Record<string, unknown>;
			const parts: string[] = [];
			for (const key of Object.keys(record).sort()) {
				const encoded = encode(record[key], false);
				if (encoded !== undefined) parts.push(`${JSON.stringify(key)}:${encoded}`);
			}
			return `{${parts.join(",")}}`;
		} finally {
			stack.delete(v);
		}
	};
	return encode(value, false) ?? "null";
}

function parseJsonObjectString(value: string): Record<string, unknown> | null {
	try {
		const parsed = JSON.parse(value);
		return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
	} catch {
		return null;
	}
}

function asRecord(value: unknown): Record<string, unknown> | null {
	if (typeof value === "object" && value !== null && !Array.isArray(value)) return value as Record<string, unknown>;
	if (typeof value === "string") return parseJsonObjectString(value);
	return null;
}

function firstStringField(record: Record<string, unknown>, keys: string[]): string | undefined {
	for (const key of keys) {
		const value = record[key];
		if (typeof value === "string" && value.trim()) return value;
	}
	return undefined;
}

function argsSummary(name: string, args: unknown): string {
	const record = asRecord(args);
	if (record) {
		const command = firstStringField(record, ["command", "cmd", "script"]);
		if (command) return truncate(command, 140);
		const filePath = firstStringField(record, ["path", "file", "filePath", "filepath", "targetFile", "targetPath"]);
		if (filePath) return truncate(filePath, 140);
	}
	if (typeof args === "string") return truncate(args, 140);
	const normalized = stableJsonStringify(args);
	return truncate(normalized === "{}" ? name : normalized, 140);
}

function toolCallObservation(event: Extract<LoopToolEvent, { kind: "tool_call" }>): ToolCallObservation {
	const toolName = String(event.name || "unknown");
	const normalizedArgs = stableJsonStringify(event.args ?? {});
	const argsHash = hashString(normalizedArgs);
	return {
		signature: `identical_tool_call:${toolName}:${argsHash}`,
		toolName,
		argsPreview: argsSummary(toolName, event.args),
	};
}

function severityForCount(count: number, config: ResolvedLoopDetectorConfig): LoopSeverity | null {
	if (count >= config.hardThreshold) return "hard";
	if (count >= config.softThreshold) return "soft";
	return null;
}

function countSignature<T extends { signature: string }>(items: T[], signature: string): number {
	let count = 0;
	for (const item of items) if (item.signature === signature) count += 1;
	return count;
}

function toolCallVerdict(observation: ToolCallObservation, count: number, config: ResolvedLoopDetectorConfig): LoopVerdict {
	const severity = severityForCount(count, config);
	if (!severity) return NO_LOOP;
	return {
		tripped: true,
		severity,
		pattern: "identical_tool_call",
		signature: observation.signature,
		summary: `identical ${observation.toolName} call x${count}: ${observation.argsPreview}`,
		evidence: {
			count,
			threshold: severity === "hard" ? config.hardThreshold : config.softThreshold,
			window: config.toolCallWindow,
			toolName: observation.toolName,
			argsPreview: observation.argsPreview,
		},
	};
}

function normalizePath(value: string): string {
	return value
		.trim()
		.replace(/^[`'"<]+/g, "")
		.replace(/[`'">,;]+$/g, "")
		.replace(/\\/g, "/")
		.replace(/^\.\//, "")
		.trim();
}

function contentFields(record: Record<string, unknown>): unknown[] {
	const direct = firstStringField(record, ["content", "newContent", "new_content", "text", "body", "replacement", "newText", "new_text", "newString", "new_string"]);
	if (direct !== undefined) return [direct];
	if (Array.isArray(record.edits)) {
		return record.edits.map((edit) => {
			if (typeof edit !== "object" || edit === null || Array.isArray(edit)) return edit;
			const editRecord = edit as Record<string, unknown>;
			return firstStringField(editRecord, ["newText", "new_text", "newString", "new_string", "replacement", "content", "text"]) ?? editRecord;
		});
	}
	return [];
}

function omitPathishFields(record: Record<string, unknown>): Record<string, unknown> {
	const pathKeys = new Set(["path", "file", "filePath", "filepath", "targetFile", "targetPath", "absolutePath"]);
	const out: Record<string, unknown> = {};
	for (const [key, value] of Object.entries(record)) {
		if (!pathKeys.has(key)) out[key] = value;
	}
	return out;
}

function editObservation(event: Extract<LoopToolEvent, { kind: "tool_call" }>, config: ResolvedLoopDetectorConfig): EditObservation | null {
	const toolName = String(event.name || "unknown");
	// Defend against callers supplying a global RegExp; repeated test() calls should be stateless.
	config.editToolPattern.lastIndex = 0;
	if (!config.editToolPattern.test(toolName)) return null;
	config.editToolPattern.lastIndex = 0;
	const record = asRecord(event.args);
	if (!record) return null;
	const filePath = firstStringField(record, ["path", "file", "filePath", "filepath", "targetFile", "targetPath", "absolutePath"]);
	if (!filePath) return null;
	const fields = contentFields(record);
	const basis = fields.length ? fields : [omitPathishFields(record)];
	const normalizedBasis = stableJsonStringify(basis);
	if (!normalizedBasis || normalizedBasis === "[{}]") return null;
	return { path: normalizePath(filePath), toolName, contentHash: hashString(normalizedBasis) };
}

function editVerdict(
	observation: EditObservation,
	sequence: EditObservation[],
	config: ResolvedLoopDetectorConfig,
): LoopVerdict {
	if (sequence.length < config.softThreshold) return NO_LOOP;
	const lastIndex = sequence.length - 1;
	for (let i = 0; i < lastIndex; i += 1) {
		if (sequence[i].contentHash !== observation.contentHash) continue;
		const cycle = sequence.slice(i, lastIndex + 1);
		if (cycle.length < config.softThreshold) continue;
		if (!cycle.some((item) => item.contentHash !== observation.contentHash)) continue;
		const count = cycle.length;
		const severity = severityForCount(count, config);
		if (!severity) continue;
		return {
			tripped: true,
			severity,
			pattern: "edit_oscillation",
			signature: `edit_oscillation:${observation.path}:${observation.contentHash}`,
			summary: `edit oscillation via ${observation.toolName} x${count} on ${observation.path}: content hash ${observation.contentHash} reappeared`,
			evidence: {
				count,
				threshold: severity === "hard" ? config.hardThreshold : config.softThreshold,
				window: config.editOscillationWindow,
				toolName: observation.toolName,
				path: observation.path,
				contentHash: observation.contentHash,
			},
		};
	}
	return NO_LOOP;
}

/** Normalize an error preview so repeated failures differing only in line numbers/timestamps coalesce. */
export function normalizeErrorPreview(preview: string, maxChars = DEFAULT_ERROR_PREVIEW_CHARS): string {
	const normalized = String(preview ?? "")
		.toLowerCase()
		.replace(/\b\d{4}-\d{2}-\d{2}[t\s]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:z|[+-]\d{2}:?\d{2})?\b/g, " ")
		.replace(/\b\d{4}-\d{2}-\d{2}\b/g, " ")
		.replace(/\b\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:z|\s?(?:am|pm))?\b/g, " ")
		.replace(/(?:^|\s)(?:[a-z]:)?(?:[./~]*[^\s:]+[\\/])+[^\s]*[a-f0-9]{7,}[^\s]*/gi, " <path> ")
		.replace(/\b[0-9a-f]{7,}\b/gi, " <hex> ")
		.replace(/\d+/g, " ")
		.replace(/\s+/g, " ")
		.trim();
	return truncate(normalized.slice(0, maxChars), maxChars);
}

function errorObservation(event: Extract<LoopToolEvent, { kind: "tool_result" }>, config: ResolvedLoopDetectorConfig): ErrorObservation | null {
	if (event.ok) return null;
	const toolName = String(event.name || "unknown");
	const preview = normalizeErrorPreview(event.preview, config.errorPreviewChars);
	if (!preview) return null;
	return {
		signature: `repeated_error_signature:${toolName}:${hashString(preview)}`,
		toolName,
		preview,
	};
}

function errorVerdict(observation: ErrorObservation, count: number, config: ResolvedLoopDetectorConfig): LoopVerdict {
	const severity = severityForCount(count, config);
	if (!severity) return NO_LOOP;
	return {
		tripped: true,
		severity,
		pattern: "repeated_error_signature",
		signature: observation.signature,
		summary: `repeated ${observation.toolName} error x${count}: ${truncate(observation.preview, 140)}`,
		evidence: {
			count,
			threshold: severity === "hard" ? config.hardThreshold : config.softThreshold,
			window: config.errorWindow,
			toolName: observation.toolName,
			preview: observation.preview,
		},
	};
}

function severityRank(verdict: LoopVerdict): number {
	if (!verdict.tripped) return 0;
	return verdict.severity === "hard" ? 2 : 1;
}

function strongerVerdict(a: LoopVerdict, b: LoopVerdict): LoopVerdict {
	return severityRank(b) > severityRank(a) ? b : a;
}

function trimWindow<T>(items: T[], max: number): void {
	while (items.length > max) items.shift();
}

/** Create a stateful within-round loop detector. */
export function createLoopDetector(configInput: LoopDetectorConfig = {}): LoopDetector {
	const config = resolveConfig(configInput);
	const toolCalls: ToolCallObservation[] = [];
	const errors: ErrorObservation[] = [];
	const editsByPath = new Map<string, EditObservation[]>();

	return {
		observe(event: LoopToolEvent): LoopVerdict {
			if (event.kind === "tool_call") {
				const call = toolCallObservation(event);
				toolCalls.push(call);
				trimWindow(toolCalls, config.toolCallWindow);
				let verdict = toolCallVerdict(call, countSignature(toolCalls, call.signature), config);

				const edit = editObservation(event, config);
				if (!edit) return verdict;
				const sequence = editsByPath.get(edit.path) ?? [];
				const previous = sequence[sequence.length - 1];
				if (!previous || previous.contentHash !== edit.contentHash) sequence.push(edit);
				trimWindow(sequence, config.editOscillationWindow);
				editsByPath.set(edit.path, sequence);
				verdict = strongerVerdict(verdict, editVerdict(edit, sequence, config));
				return verdict;
			}

			const error = errorObservation(event, config);
			if (!error) return NO_LOOP;
			errors.push(error);
			trimWindow(errors, config.errorWindow);
			return errorVerdict(error, countSignature(errors, error.signature), config);
		},

		snapshot(): LoopDetectorSnapshot {
			const toolCallCounts = new Map<string, { count: number; toolName: string; summary: string }>();
			for (const call of toolCalls) {
				const current = toolCallCounts.get(call.signature) ?? { count: 0, toolName: call.toolName, summary: call.argsPreview };
				current.count += 1;
				toolCallCounts.set(call.signature, current);
			}
			const errorCounts = new Map<string, { count: number; toolName: string; preview: string }>();
			for (const error of errors) {
				const current = errorCounts.get(error.signature) ?? { count: 0, toolName: error.toolName, preview: error.preview };
				current.count += 1;
				errorCounts.set(error.signature, current);
			}
			return {
				config: {
					softThreshold: config.softThreshold,
					hardThreshold: config.hardThreshold,
					toolCallWindow: config.toolCallWindow,
					errorWindow: config.errorWindow,
					editOscillationWindow: config.editOscillationWindow,
					errorPreviewChars: config.errorPreviewChars,
					editToolPattern: config.editToolPattern.source,
				},
				toolCalls: [...toolCallCounts.entries()].map(([signature, value]) => ({ signature, ...value })),
				errors: [...errorCounts.entries()].map(([signature, value]) => ({ signature, ...value })),
				edits: [...editsByPath.entries()].map(([path, sequence]) => ({ path, hashes: sequence.map((item) => item.contentHash) })),
			};
		},
	};
}
