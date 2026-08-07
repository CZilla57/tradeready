// Non-synced, device-local record of CSV import batches. Powers the same-file
// re-import warning and the report history. Deliberately NOT a synced collection
// (it's per-device operational metadata, not business data) — plain AsyncStorage.

import AsyncStorage from "@react-native-async-storage/async-storage";
import type { ImportEntity } from "./importMapping";
import type { ImportCounts } from "./importEngine";

const KEY = "tr_import_history_v1";

let _batchCounter = 0;
export function newBatchId(): string {
  _batchCounter += 1;
  return `imp_${Date.now()}_${_batchCounter}`;
}

export interface ImportBatchRecord {
  batchId: string;
  entity: ImportEntity;
  fileHash: string;
  date: string;
  counts: ImportCounts;
}

export async function loadImportHistory(): Promise<ImportBatchRecord[]> {
  try {
    const raw = await AsyncStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as ImportBatchRecord[]) : [];
  } catch {
    return [];
  }
}

export async function recordImportBatch(rec: ImportBatchRecord): Promise<void> {
  const hist = await loadImportHistory();
  await AsyncStorage.setItem(KEY, JSON.stringify([rec, ...hist]));
}

export async function findBatchByFileHash(
  entity: ImportEntity,
  fileHash: string,
): Promise<ImportBatchRecord | null> {
  const hist = await loadImportHistory();
  return hist.find((h) => h.entity === entity && h.fileHash === fileHash) ?? null;
}
