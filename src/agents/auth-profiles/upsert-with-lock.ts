/**
 * Locked auth profile upsert helper.
 * Normalizes literal secrets before persistence and routes all writes through
 * the shared SQLite lock to avoid racing concurrent auth updates.
 */
import { normalizeAuthProfileCredential } from "./credential-normalize.js";
import { updateAuthProfileStoreWithLock } from "./store.js";
import type { AuthProfileCredential, AuthProfileStore } from "./types.js";
import { resetAuthProfileFailureState } from "./usage-state.js";

type AuthProfileUpsertParams = {
  profileId: string;
  credential: AuthProfileCredential;
  agentDir?: string;
  stateDir?: string;
};

function throwAuthProfileUpdateError(): never {
  throw new Error(
    "Failed to update auth profile store; the auth store lock may be busy. Wait a moment and retry.",
  );
}

async function upsertAuthProfileWithLockCore(
  params: AuthProfileUpsertParams,
  resetFailureState: boolean,
): Promise<AuthProfileStore | null> {
  const credential = normalizeAuthProfileCredential(params.credential);
  return await updateAuthProfileStoreWithLock({
    agentDir: params.agentDir,
    stateDir: params.stateDir,
    saveOptions: {
      filterExternalAuthProfiles: false,
      syncExternalCli: false,
    },
    updater: (store) => {
      store.profiles[params.profileId] = credential;
      if (resetFailureState && store.usageStats?.[params.profileId]) {
        store.usageStats[params.profileId] = resetAuthProfileFailureState(
          store.usageStats[params.profileId],
        );
      }
      return true;
    },
  });
}

/** Upserts an auth profile under the store lock, returning null on store write failure. */
export async function upsertAuthProfileWithLock(
  params: AuthProfileUpsertParams,
): Promise<AuthProfileStore | null> {
  return await upsertAuthProfileWithLockCore(params, false);
}

/** Upserts an auth profile under the store lock, failing when the store cannot be written. */
export async function upsertAuthProfileWithLockOrThrow(
  params: Parameters<typeof upsertAuthProfileWithLock>[0],
): Promise<void> {
  const updated = await upsertAuthProfileWithLock(params);
  if (!updated) {
    throwAuthProfileUpdateError();
  }
}

/** Atomically persists a completed login and clears failure state from the replaced credential. */
export async function upsertAuthProfileAfterLoginWithLockOrThrow(
  params: AuthProfileUpsertParams,
): Promise<void> {
  const updated = await upsertAuthProfileWithLockCore(params, true);
  if (!updated) {
    throwAuthProfileUpdateError();
  }
}
