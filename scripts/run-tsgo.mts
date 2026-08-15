// Runs tsgo through local heavy-check policy and sparse-checkout guards.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { readFlagValue } from "./lib/arg-utils.mts";
import {
  acquireLocalHeavyCheckLockSync,
  applyLocalTsgoPolicy,
  ensureRepoToolNodeModulesLink,
  resolveLocalHeavyCheckEnv,
  resolveRepoToolBinPath,
  shouldAcquireLocalHeavyCheckLockForTsgo,
} from "./lib/local-heavy-check-runtime.mts";
import { runManagedCommand } from "./lib/managed-child-process.mts";
import { readPositiveEnvInt } from "./lib/numeric-options.mjs";
import {
  getSparseTsgoGuardError,
  shouldSkipSparseTsgoGuardError,
} from "./lib/tsgo-sparse-guard.mts";

/** Watchdog bound for one tsgo run; sized well above a healthy whole-program check. */
const DEFAULT_TSGO_TIMEOUT_MS = 45 * 60 * 1000;
/** Node's timer ceiling: a longer delay silently becomes 1ms, so a raised override must saturate. */
const MAX_TSGO_TIMEOUT_MS = 2_147_483_647;

async function main(): Promise<void> {
  const hostResources = {
    logicalCpuCount:
      typeof os.availableParallelism === "function" ? os.availableParallelism() : os.cpus().length,
    totalMemoryBytes: os.totalmem(),
  };
  const { args: finalArgs, env } = applyLocalTsgoPolicy(
    process.argv.slice(2),
    resolveLocalHeavyCheckEnv(process.env),
    hostResources,
  );

  const tsgoPath = resolveRepoToolBinPath("tsgo");
  const tsBuildInfoFile = readFlagValue(finalArgs, "--tsBuildInfoFile");
  if (tsBuildInfoFile) {
    fs.mkdirSync(path.dirname(path.resolve(tsBuildInfoFile)), { recursive: true });
  }
  const sparseGuardError = getSparseTsgoGuardError(finalArgs, { cwd: process.cwd() });
  const releaseLock =
    sparseGuardError ||
    env.OPENCLAW_TSGO_HEAVY_CHECK_LOCK_HELD === "1" ||
    !shouldAcquireLocalHeavyCheckLockForTsgo(finalArgs, env)
      ? () => {}
      : acquireLocalHeavyCheckLockSync({
          cwd: process.cwd(),
          env,
          toolName: "tsgo",
        });

  try {
    if (sparseGuardError) {
      console.error(sparseGuardError);
      if (shouldSkipSparseTsgoGuardError(env)) {
        console.error("[tsgo] skipping sparse-missing project because OPENCLAW_TSGO_SPARSE_SKIP=1");
        process.exitCode = 0;
      } else {
        process.exitCode = 1;
      }
    } else {
      ensureRepoToolNodeModulesLink(tsgoPath);
      const timeoutMs = Math.min(
        readPositiveEnvInt("OPENCLAW_TSGO_TIMEOUT_MS", env, DEFAULT_TSGO_TIMEOUT_MS),
        MAX_TSGO_TIMEOUT_MS,
      );
      try {
        // Managed run owns the whole tsgo process tree: a wedged checker ignores
        // SIGTERM, so the watchdog escalates to SIGKILL instead of blocking the
        // caller forever on a compiler that will never report.
        process.exitCode = await runManagedCommand({
          bin: tsgoPath,
          args: finalArgs,
          env,
          timeoutMs,
        });
      } catch (error) {
        if ((error as { code?: string } | undefined)?.code !== "ETIMEDOUT") {
          throw error;
        }
        console.error(
          `[tsgo] no completion after ${timeoutMs}ms; killed the tsgo process tree. Raise OPENCLAW_TSGO_TIMEOUT_MS for intentionally longer builds.`,
        );
        process.exitCode = 1;
      }
    }
  } finally {
    releaseLock();
  }
}

if (import.meta.main) {
  await main();
}
