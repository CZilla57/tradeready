import '@testing-library/jest-dom/vitest';
import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/react';

// Unmount React trees and reset jsdom between tests so state (and the
// sessionStorage recovery flag) never leaks across cases.
afterEach(() => {
  cleanup();
  try {
    window.sessionStorage.clear();
    window.localStorage.clear();
  } catch {
    // ignore storage-less environments
  }
});
