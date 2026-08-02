// __tests__/UndoContext.test.tsx
// Pins the global undo snackbar (context/UndoContext.tsx): showUndo surfaces
// the message with an UNDO button, UNDO runs the restore exactly once and
// dismisses, the window auto-expires after UNDO_WINDOW_MS, and a second
// showUndo replaces the first (its timer included).
// RNTL v14 ships an async render() — every test must await it.
import React from 'react';
import { Text } from 'react-native';
import { render, fireEvent, act } from '@testing-library/react-native';
import { UndoProvider, useUndo, UNDO_WINDOW_MS } from '../context/UndoContext';

jest.mock('../context/ThemeContext', () => ({
  useThemeContext: () => ({
    colors: {
      background: '#ffffff',
      textPrimary: '#1c1c1e',
      accent: '#2f6fed',
    },
    shadow: { card: {} },
  }),
}));
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 44, bottom: 0, left: 0, right: 0 }),
}));
// Deterministic animations: collapse to duration 0 so mount/unmount settles
// within the same act() tick.
jest.mock('../utils/motion', () => ({
  animationDuration: () => 0,
  useReduceMotion: () => true,
}));

function Trigger({ message, onUndo }: { message: string; onUndo: () => void }) {
  const { showUndo } = useUndo();
  return <Text onPress={() => showUndo(message, onUndo)}>trigger-{message}</Text>;
}

beforeEach(() => {
  jest.useFakeTimers();
});

afterEach(() => {
  jest.useRealTimers();
});

describe('UndoProvider', () => {
  it('renders no snackbar until showUndo is called', async () => {
    const { queryByText } = await render(
      <UndoProvider>
        <Trigger message="Job deleted" onUndo={jest.fn()} />
      </UndoProvider>
    );
    expect(queryByText('Job deleted')).toBeNull();
    expect(queryByText('UNDO')).toBeNull();
  });

  it('shows the message and UNDO after showUndo', async () => {
    const { getByText } = await render(
      <UndoProvider>
        <Trigger message="Job deleted" onUndo={jest.fn()} />
      </UndoProvider>
    );
    await act(async () => { fireEvent.press(getByText('trigger-Job deleted')); });
    expect(getByText('Job deleted')).toBeTruthy();
    expect(getByText('UNDO')).toBeTruthy();
  });

  it('UNDO runs the restore once and dismisses the snackbar', async () => {
    const onUndo = jest.fn();
    const { getByText, queryByText } = await render(
      <UndoProvider>
        <Trigger message="Invoice deleted" onUndo={onUndo} />
      </UndoProvider>
    );
    await act(async () => { fireEvent.press(getByText('trigger-Invoice deleted')); });
    await act(async () => { fireEvent.press(getByText('UNDO')); });
    expect(onUndo).toHaveBeenCalledTimes(1);
    expect(queryByText('Invoice deleted')).toBeNull();
  });

  it('auto-dismisses after the undo window; the restore never runs', async () => {
    const onUndo = jest.fn();
    const { getByText, queryByText } = await render(
      <UndoProvider>
        <Trigger message="Expense deleted" onUndo={onUndo} />
      </UndoProvider>
    );
    await act(async () => { fireEvent.press(getByText('trigger-Expense deleted')); });
    expect(getByText('Expense deleted')).toBeTruthy();
    await act(async () => { jest.advanceTimersByTime(UNDO_WINDOW_MS + 100); });
    expect(queryByText('Expense deleted')).toBeNull();
    expect(onUndo).not.toHaveBeenCalled();
  });

  it('a second showUndo replaces the first, and UNDO restores only the second', async () => {
    const firstUndo = jest.fn();
    const secondUndo = jest.fn();
    const { getByText, queryByText } = await render(
      <UndoProvider>
        <Trigger message="Job deleted" onUndo={firstUndo} />
        <Trigger message="Invoice deleted" onUndo={secondUndo} />
      </UndoProvider>
    );
    await act(async () => { fireEvent.press(getByText('trigger-Job deleted')); });
    // Nearly let the first window lapse, then trigger the second.
    await act(async () => { jest.advanceTimersByTime(UNDO_WINDOW_MS - 500); });
    await act(async () => { fireEvent.press(getByText('trigger-Invoice deleted')); });
    expect(queryByText('Job deleted')).toBeNull();
    // The first request's timer must not kill the second's window.
    await act(async () => { jest.advanceTimersByTime(1000); });
    expect(getByText('Invoice deleted')).toBeTruthy();
    await act(async () => { fireEvent.press(getByText('UNDO')); });
    expect(secondUndo).toHaveBeenCalledTimes(1);
    expect(firstUndo).not.toHaveBeenCalled();
  });
});
