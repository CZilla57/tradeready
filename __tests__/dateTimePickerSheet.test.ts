// __tests__/dateTimePickerSheet.test.ts
// Pins roundToMinuteInterval: incoming picker values snap to the interval so
// pre-existing odd times (9:37) don't confuse the iOS spinner, with hour
// carry and a never-roll-to-next-day clamp.
//
// Also pins the iOS sheet's commit-on-Done contract (owner requirement,
// 2026-07-16): Done commits the currently displayed value even when the
// picker was never touched, so opening with nothing selected and tapping Done
// picks the parent's fallback. That contract is NOT first covered here —
// UI.test.js:159 has asserted it since the requirement landed, and still
// passes. These cases sit with the sheet's own suite and add what that one
// does not: the picker-still-reachable guard for the ScrollView that Phase 6
// of the iPad work wrapped around the inline calendar, and the
// roundToMinuteInterval path through Done.
//
// This file is .ts, not .tsx, so the render cases use React.createElement
// rather than JSX.
//
// RNTL v14 ships an async render() AND async fireEvent — every call must be
// awaited, or the next line reads state before the update lands.

import React from 'react';
import { Platform } from 'react-native';
import { render, fireEvent } from '@testing-library/react-native';
import {
  DateTimePickerSheet,
  roundToMinuteInterval,
} from '../components/DateTimePickerSheet';

function at(h: number, m: number): Date {
  const d = new Date(2026, 7, 1);
  d.setHours(h, m, 0, 0);
  return d;
}

describe('roundToMinuteInterval', () => {
  test('rounds to the nearest interval multiple', () => {
    const r = roundToMinuteInterval(at(9, 37), 5);
    expect(r.getHours()).toBe(9);
    expect(r.getMinutes()).toBe(35);
  });

  test('rounds up with hour carry', () => {
    const r = roundToMinuteInterval(at(9, 58), 5);
    expect(r.getHours()).toBe(10);
    expect(r.getMinutes()).toBe(0);
  });

  test('exact multiples are unchanged', () => {
    const r = roundToMinuteInterval(at(14, 30), 5);
    expect(r.getHours()).toBe(14);
    expect(r.getMinutes()).toBe(30);
  });

  test('never rolls into the next day', () => {
    const r = roundToMinuteInterval(at(23, 59), 5);
    expect(r.getHours()).toBe(23);
    expect(r.getMinutes()).toBe(55);
    expect(r.getDate()).toBe(1);
  });

  test('no interval returns the value untouched', () => {
    const v = at(9, 37);
    expect(roundToMinuteInterval(v, undefined)).toBe(v);
  });
});

describe('DateTimePickerSheet — iOS sheet', () => {
  const originalOS = Platform.OS;
  beforeEach(() => {
    Platform.OS = 'ios';
  });
  afterEach(() => {
    Platform.OS = originalOS;
  });

  function sheet(over: Partial<React.ComponentProps<typeof DateTimePickerSheet>> = {}) {
    const props: React.ComponentProps<typeof DateTimePickerSheet> = {
      visible: true,
      mode: 'date',
      value: at(9, 0),
      title: 'Job date',
      onChange: jest.fn(),
      onClose: jest.fn(),
      ...over,
    };
    return React.createElement(DateTimePickerSheet, props);
  }

  test('renders nothing when not visible', async () => {
    const { queryByLabelText } = await render(sheet({ visible: false }));
    expect(queryByLabelText('Done')).toBeNull();
  });

  test('the calendar branch keeps both the picker and Done reachable', async () => {
    const { getByLabelText, getByTestId } = await render(sheet({ mode: 'date' }));
    expect(getByTestId('mock-datetime-picker')).toBeTruthy();
    expect(getByLabelText('Done')).toBeTruthy();
  });

  test('Done commits the displayed value even when the picker was never touched', async () => {
    const onChange = jest.fn();
    const onClose = jest.fn();
    const value = at(9, 0);
    const { getByLabelText } = await render(sheet({ value, onChange, onClose }));

    await fireEvent.press(getByLabelText('Done'));

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith(value);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  test('Done commits the interval-rounded value in time mode', async () => {
    const onChange = jest.fn();
    const { getByLabelText } = await render(
      sheet({ mode: 'time', value: at(9, 37), minuteInterval: 5, onChange })
    );

    await fireEvent.press(getByLabelText('Done'));

    const committed = onChange.mock.calls[0][0] as Date;
    expect(committed.getHours()).toBe(9);
    expect(committed.getMinutes()).toBe(35);
  });
});
