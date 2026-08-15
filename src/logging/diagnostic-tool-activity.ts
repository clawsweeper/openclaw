export type DiagnosticActiveTool = {
  runId?: string;
  sessionId?: string;
  sessionKey?: string;
  sequence?: number;
  toolName: string;
  toolCallId?: string;
  startedAt: number;
  lastProgressAt: number;
  lastProgressReason: string;
};

type ToolRef = Pick<DiagnosticActiveTool, "runId" | "sessionId" | "sessionKey" | "toolCallId"> & {
  toolName?: string;
};

export function diagnosticToolKey(tool: ToolRef): string {
  return `${tool.runId ?? tool.sessionId ?? tool.sessionKey ?? "unknown"}:${
    tool.toolCallId ?? tool.toolName ?? "unknown"
  }`;
}

export function resolveDiagnosticProgressTool(
  activeTools: ReadonlyMap<string, DiagnosticActiveTool>,
  progress: ToolRef,
): DiagnosticActiveTool | undefined {
  if (progress.toolCallId) {
    return activeTools.get(diagnosticToolKey(progress));
  }
  // Unscoped progress proves liveness only when one tool can own it. With
  // overlapping calls, refreshing all markers can hide an orphan forever.
  return activeTools.size === 1 ? activeTools.values().next().value : undefined;
}
