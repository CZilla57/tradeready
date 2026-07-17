/**
 * Smoke tests for the UI component library.
 * RNTL v14 ships an async render() — every test must await it.
 */
import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import { Badge, Button, Card, Divider, EmptyState, SectionHeader, StatCard } from "../components/UI";
import { Text, Platform } from "react-native";
import Field from "../components/Field";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";

describe("Badge", () => {
  it("renders its label text", async () => {
    const { getByText } = await render(<Badge label="7d overdue" color="danger" />);
    expect(getByText("7d overdue")).toBeTruthy();
  });

  it("renders with default color prop without crashing", async () => {
    const { getByText } = await render(<Badge label="Paid" />);
    expect(getByText("Paid")).toBeTruthy();
  });

  it("exposes its label to the accessibility tree", async () => {
    const { getByRole } = await render(<Badge label="Overdue" color="danger" />);
    expect(getByRole("text", { name: "Overdue" })).toBeTruthy();
  });
});

describe("Button", () => {
  it("renders its label text", async () => {
    const { getByText } = await render(<Button label="Save" onPress={() => {}} />);
    expect(getByText("Save")).toBeTruthy();
  });

  it("renders ghost variant without crashing", async () => {
    const { getByText } = await render(
      <Button label="Cancel" variant="ghost" onPress={() => {}} />
    );
    expect(getByText("Cancel")).toBeTruthy();
  });

  it("hides label and shows spinner when loading", async () => {
    const { queryByText } = await render(<Button label="Save" onPress={() => {}} loading />);
    expect(queryByText("Save")).toBeNull();
  });

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
});

describe("EmptyState", () => {
  it("renders its message text", async () => {
    const { getByText } = await render(
      <EmptyState message="No jobs yet. Add your first job to get started." />
    );
    expect(getByText("No jobs yet. Add your first job to get started.")).toBeTruthy();
  });
});

describe("SectionHeader", () => {
  it("renders its title text", async () => {
    const { getByText } = await render(<SectionHeader title="Recent Jobs" />);
    expect(getByText("Recent Jobs")).toBeTruthy();
  });

  it("is exposed as a header to the accessibility tree", async () => {
    const { getByRole } = await render(<SectionHeader title="Recent Jobs" />);
    expect(getByRole("header", { name: "Recent Jobs" })).toBeTruthy();
  });
});

describe("StatCard", () => {
  it("renders both label and value", async () => {
    const { getByText } = await render(
      <StatCard label="Total revenue" value="$4,200" />
    );
    expect(getByText("Total revenue")).toBeTruthy();
    expect(getByText("$4,200")).toBeTruthy();
  });

  it("groups label and value into one accessibility element", async () => {
    const { getByLabelText } = await render(
      <StatCard label="Outstanding" value="$4,200" />
    );
    expect(getByLabelText("Outstanding: $4,200")).toBeTruthy();
  });
});

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

describe("Divider", () => {
  it("is hidden from the accessibility tree", async () => {
    const { root } = await render(<Divider />);
    expect(root.props.accessibilityElementsHidden).toBe(true);
    expect(root.props.importantForAccessibility).toBe("no");
  });
});

describe("Field", () => {
  it("labels the text input for screen readers", async () => {
    const { getByLabelText } = await render(
      <Field label="Email" value="" onChangeText={() => {}} />
    );
    const input = getByLabelText("Email");
    expect(input).toBeTruthy();
  });
});

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

  // Owner report 2026-07-16: opening a picker with nothing selected and
  // tapping Done must select the displayed fallback (today/now) — before
  // this, users had to scroll to another value and back to pick it.
  it("Done commits the currently displayed value before closing (iOS)", async () => {
    Platform.OS = "ios";
    const shown = new Date(2026, 6, 16);
    const onChange = jest.fn();
    const onClose = jest.fn();
    const { getByRole } = await render(
      <DateTimePickerSheet
        visible={true}
        mode="date"
        value={shown}
        title="Select date"
        onChange={onChange}
        onClose={onClose}
      />
    );
    fireEvent.press(getByRole("button", { name: "Done" }));
    expect(onChange).toHaveBeenCalledWith(shown);
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
