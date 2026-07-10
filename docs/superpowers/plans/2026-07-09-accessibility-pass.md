# Accessibility Pass — Shared Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add screen-reader labels and roles to the 7 shared UI components so VoiceOver/TalkBack can announce every interactive element they render.

**Architecture:** Props-only changes — add `accessibilityLabel`, `accessibilityRole`, and `accessibilityState` to the JSX elements inside each component, derived from props they already receive. Zero new props, zero consumer changes.

**Tech Stack:** React Native (0.81), RNTL v14 (async `render()`), Jest

## Global Constraints

- Gate must stay green after every task: `npm run typecheck` (0 errors), `npm test` (347+ tests), `npm run lint` (0 warnings)
- No new dependencies
- No new props on any component — labels derived from existing props only
- No visual changes — a11y props are invisible to sighted users
- Test pattern: RNTL v14 async render — every test must `await render()`
- All commands run from `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\`

---

### Task 1: UI.tsx — Badge, Button, StatCard, SectionHeader, Divider

**Files:**
- Modify: `components/UI.tsx`
- Modify: `__tests__/UI.test.js`

**Interfaces:**
- Consumes: nothing new
- Produces: Badge with `accessibilityRole="text"` + label; Button with `accessibilityRole="button"` + label + state; StatCard with `accessible={true}` + combined label; SectionHeader with `accessibilityRole="header"`; Divider hidden from a11y tree

- [ ] **Step 1: Write failing tests for Badge a11y**

Add to the existing Badge describe block in `__tests__/UI.test.js`:

```js
it("exposes its label to the accessibility tree", async () => {
  const { getByRole } = await render(<Badge label="Overdue" color="danger" />);
  expect(getByRole("text", { name: "Overdue" })).toBeTruthy();
});
```

- [ ] **Step 2: Write failing tests for Button a11y**

Add to the existing Button describe block:

```js
it("exposes role and label to the accessibility tree", async () => {
  const { getByRole } = await render(<Button label="Save" onPress={() => {}} />);
  expect(getByRole("button", { name: "Save" })).toBeTruthy();
});

it("reports busy state when loading", async () => {
  const { getByRole } = await render(<Button label="Save" onPress={() => {}} loading />);
  const btn = getByRole("button", { name: "Save" });
  expect(btn.props.accessibilityState).toEqual(
    expect.objectContaining({ disabled: true, busy: true })
  );
});
```

- [ ] **Step 3: Write failing tests for StatCard a11y**

Add to the existing StatCard describe block:

```js
it("groups label and value into one accessibility element", async () => {
  const { getByLabelText } = await render(
    <StatCard label="Outstanding" value="$4,200" />
  );
  expect(getByLabelText("Outstanding: $4,200")).toBeTruthy();
});
```

- [ ] **Step 4: Write failing tests for SectionHeader a11y**

Add to the existing SectionHeader describe block:

```js
it("is exposed as a header to the accessibility tree", async () => {
  const { getByRole } = await render(<SectionHeader title="Recent Jobs" />);
  expect(getByRole("header", { name: "Recent Jobs" })).toBeTruthy();
});
```

- [ ] **Step 5: Write failing test for Divider a11y**

Add a new describe block:

```js
describe("Divider", () => {
  it("is hidden from the accessibility tree", async () => {
    const { UNSAFE_getByType } = await render(<Divider />);
    const divider = UNSAFE_getByType(View);
    expect(divider.props.accessibilityElementsHidden).toBe(true);
    expect(divider.props.importantForAccessibility).toBe("no");
  });
});
```

Add `Divider` to the import at the top: `import { Badge, Button, Divider, EmptyState, SectionHeader, StatCard } from "../components/UI";`

Also add `View` to the RN import: `import { View } from "react-native";`

- [ ] **Step 6: Run tests to verify they fail**

Run: `npm test -- --testPathPattern=UI.test`
Expected: 6 new tests FAIL (no a11y props yet)

- [ ] **Step 7: Implement a11y props in UI.tsx**

In `Badge` — add `accessibilityRole` and `accessibilityLabel` to the outer View:

```tsx
<View
  style={[styles.badge, { backgroundColor: bgMap[color] || bgMap.muted }]}
  accessibilityRole="text"
  accessibilityLabel={label}
>
```

In `Button` — add `accessibilityRole`, `accessibilityLabel`, and `accessibilityState` to the TouchableOpacity:

```tsx
<TouchableOpacity
  style={[
    styles.btn,
    isPrimary
      ? { backgroundColor: colors.accent }
      : { backgroundColor: "transparent", borderWidth: 1, borderColor: colors.borderStrong },
    style,
  ]}
  onPress={onPress}
  activeOpacity={0.75}
  disabled={loading}
  accessibilityRole="button"
  accessibilityLabel={label}
  accessibilityState={{ disabled: !!loading, busy: !!loading }}
>
```

In `StatCard` — add `accessible` and `accessibilityLabel` to the outer View:

```tsx
<View
  style={[styles.statCard, { backgroundColor: colors.surface, ...shadow.card }]}
  accessible={true}
  accessibilityLabel={`${label}: ${value}`}
>
```

In `SectionHeader` — add `accessibilityRole` to the Text:

```tsx
<Text
  style={[styles.sectionHeader, { color: colors.textSecondary }]}
  accessibilityRole="header"
>
  {title}
</Text>
```

In `Divider` — add `accessibilityElementsHidden` and `importantForAccessibility` to the View:

```tsx
<View
  style={[styles.divider, { backgroundColor: colors.border }]}
  accessibilityElementsHidden={true}
  importantForAccessibility="no"
/>
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `npm test -- --testPathPattern=UI.test`
Expected: All tests PASS (existing 7 + 6 new = 13)

- [ ] **Step 9: Run full gate**

Run: `npm run typecheck`
Expected: 0 errors

Run: `npm test`
Expected: 353 tests, 31 suites, all pass

Run: `npm run lint`
Expected: 0 warnings

- [ ] **Step 10: Commit**

```bash
git add components/UI.tsx __tests__/UI.test.js
git commit -m "feat(a11y): add accessibility props to shared UI components

Badge, Button, StatCard, SectionHeader, Divider — labels and roles
derived from existing props, zero consumer changes.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: UI.tsx — Card (tappable variant)

**Files:**
- Modify: `components/UI.tsx`
- Modify: `__tests__/UI.test.js`

**Interfaces:**
- Consumes: nothing new
- Produces: Card with `accessibilityRole="button"` when `onPress` is set

- [ ] **Step 1: Write failing test for tappable Card a11y**

Add a new describe block to `__tests__/UI.test.js`:

```js
describe("Card", () => {
  it("exposes button role when tappable", async () => {
    const { getByRole } = await render(
      <Card onPress={() => {}}>
        <Text>Job details</Text>
      </Card>
    );
    expect(getByRole("button")).toBeTruthy();
  });

  it("does not expose button role when static", async () => {
    const { queryByRole } = await render(
      <Card>
        <Text>Info</Text>
      </Card>
    );
    expect(queryByRole("button")).toBeNull();
  });
});
```

Add `Card` to the UI import: `import { Badge, Button, Card, Divider, EmptyState, SectionHeader, StatCard } from "../components/UI";`

Add `Text` to the RN import: `import { Text, View } from "react-native";`

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --testPathPattern=UI.test`
Expected: 2 new Card tests FAIL

- [ ] **Step 3: Implement a11y on Card's tappable branch**

In `Card`, add `accessibilityRole="button"` to the TouchableOpacity:

```tsx
if (onPress) {
  return (
    <TouchableOpacity style={cardStyle} onPress={onPress} activeOpacity={0.8} accessibilityRole="button">
      {children}
    </TouchableOpacity>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- --testPathPattern=UI.test`
Expected: All 15 tests PASS

- [ ] **Step 5: Run full gate**

Run: `npm run typecheck`
Expected: 0 errors

Run: `npm test`
Expected: 355 tests, 31 suites

Run: `npm run lint`
Expected: 0 warnings

- [ ] **Step 6: Commit**

```bash
git add components/UI.tsx __tests__/UI.test.js
git commit -m "feat(a11y): add button role to tappable Card

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Field.tsx — TextInput label

**Files:**
- Modify: `components/Field.tsx`
- Modify: `__tests__/UI.test.js` (add Field tests to the same file — shared component, same test home)

**Interfaces:**
- Consumes: nothing new
- Produces: Field's TextInput exposes `accessibilityLabel={label}`

- [ ] **Step 1: Write failing test for Field a11y**

Add a new describe block and import to `__tests__/UI.test.js`:

```js
import Field from "../components/Field";
```

```js
describe("Field", () => {
  it("labels the text input for screen readers", async () => {
    const { getByLabelText } = await render(
      <Field label="Email" value="" onChangeText={() => {}} />
    );
    const input = getByLabelText("Email");
    expect(input).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- --testPathPattern=UI.test`
Expected: Field test FAILS (no `accessibilityLabel` on TextInput yet)

- [ ] **Step 3: Add accessibilityLabel to TextInput in Field.tsx**

In `Field`, add `accessibilityLabel={label}` to the TextInput:

```tsx
<TextInput
  style={[styles.input, multiline && styles.inputMulti, inputStyle]}
  value={value}
  onChangeText={onChangeText}
  onBlur={onBlur}
  placeholder={placeholder}
  placeholderTextColor={colors.textMuted}
  keyboardType={keyboardType || "default"}
  autoCapitalize={cap}
  autoCorrect={false}
  multiline={multiline}
  numberOfLines={multiline ? 3 : 1}
  autoFocus={autoFocus}
  accessibilityLabel={label}
/>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- --testPathPattern=UI.test`
Expected: All 16 tests PASS

- [ ] **Step 5: Run full gate**

Run: `npm run typecheck`
Expected: 0 errors

Run: `npm test`
Expected: 356 tests, 31 suites

Run: `npm run lint`
Expected: 0 warnings

- [ ] **Step 6: Commit**

```bash
git add components/Field.tsx __tests__/UI.test.js
git commit -m "feat(a11y): label Field TextInput for screen readers

Derives accessibilityLabel from the existing label prop — every
Field-using form (6 screens) gets labeled inputs automatically.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: DateTimePickerSheet.tsx — Modal and Done button

**Files:**
- Modify: `components/DateTimePickerSheet.tsx`
- Modify: `__tests__/UI.test.js`

**Interfaces:**
- Consumes: nothing new
- Produces: iOS Modal has `accessibilityLabel={title}`; Done button has `accessibilityRole="button"` + `accessibilityLabel="Done"`

- [ ] **Step 1: Add a jest mock for @react-native-community/datetimepicker**

The native DateTimePicker module has no jest mock configured. Add one to `jest.setup.js`:

```js
jest.mock("@react-native-community/datetimepicker", () => {
  const { View } = require("react-native");
  return {
    __esModule: true,
    default: (props) => <View testID="mock-datetime-picker" {...props} />,
  };
});
```

- [ ] **Step 2: Write failing test for DateTimePickerSheet a11y**

Add import and describe block to `__tests__/UI.test.js`:

```js
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { Platform } from "react-native";
```

```js
describe("DateTimePickerSheet", () => {
  const originalOS = Platform.OS;
  afterEach(() => { Platform.OS = originalOS; });

  it("labels the Done button for screen readers (iOS)", async () => {
    Platform.OS = "ios";
    const { getByRole } = await render(
      <DateTimePickerSheet
        visible={true}
        mode="date"
        value={new Date(2026, 6, 9)}
        title="Select date"
        onChange={() => {}}
        onClose={() => {}}
      />
    );
    expect(getByRole("button", { name: "Done" })).toBeTruthy();
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npm test -- --testPathPattern=UI.test`
Expected: DateTimePickerSheet test FAILS (no a11y props on Done button)

- [ ] **Step 4: Implement a11y props on DateTimePickerSheet**

In the iOS branch, add `accessibilityLabel={title}` to the Modal:

```tsx
<Modal transparent animationType="slide" accessibilityLabel={title}>
```

Add `accessibilityRole="button"` and `accessibilityLabel="Done"` to the Done TouchableOpacity:

```tsx
<TouchableOpacity
  onPress={onClose}
  accessibilityRole="button"
  accessibilityLabel="Done"
>
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npm test -- --testPathPattern=UI.test`
Expected: All 17 tests PASS

- [ ] **Step 6: Run full gate**

Run: `npm run typecheck`
Expected: 0 errors

Run: `npm test`
Expected: 357 tests, 31 suites

Run: `npm run lint`
Expected: 0 warnings

- [ ] **Step 7: Commit**

```bash
git add components/DateTimePickerSheet.tsx __tests__/UI.test.js jest.setup.js
git commit -m "feat(a11y): label DateTimePickerSheet modal and Done button

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```
