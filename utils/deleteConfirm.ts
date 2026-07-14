// Typed-confirmation gate for the permanent account wipe. A single tap on a
// destructive alert is too easy to hit by accident for an action that
// server-side-deletes every record; requiring the phrase makes it deliberate.
// Case/whitespace are forgiven (mobile keyboards auto-capitalize
// unpredictably) but the trimmed word must be exactly the phrase.

export const DELETE_CONFIRM_PHRASE = "DELETE";

export function deleteConfirmMatches(input: string): boolean {
  return input.trim().toUpperCase() === DELETE_CONFIRM_PHRASE;
}
