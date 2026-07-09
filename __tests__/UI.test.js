/**
 * Smoke tests for the UI component library.
 * RNTL v14 ships an async render() — every test must await it.
 */
import React from "react";
import { render } from "@testing-library/react-native";
import { Badge, Button, Card, Divider, EmptyState, SectionHeader, StatCard } from "../components/UI";
import { Text } from "react-native";

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
