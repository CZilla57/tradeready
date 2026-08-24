// Regression: the labor-breakdown bucket inputs and the direct-cost numeric
// inputs must allow a partial decimal ("0." on the way to "0.5"). The original
// controlled inputs reformatted the field from the parsed number on every
// keystroke, stripping the trailing "." so a decimal could never be typed.

import React, { useState } from "react";
import { render, fireEvent } from "@testing-library/react-native";
import { LaborHoursEditor, type LaborHoursValue } from "../components/LaborHoursEditor";
import { JobCostsEditor } from "../components/JobCostsEditor";
import type { JobCost } from "../types/models";

function LaborHarness() {
  const [v, setV] = useState<LaborHoursValue>({
    hours: "0",
    breakdown: { onSiteHours: 0, driveHours: 0, supplyRunHours: 0, setupCleanupHours: 0 },
  });
  return <LaborHoursEditor value={v} onChange={setV} />;
}

function JobCostsHarness() {
  const [v, setV] = useState<JobCost[]>([
    { id: "jc1", label: "", category: "other", quantity: 1, unitCost: 0, markupPercent: 0, markupPolicy: "in_margin_base", taxable: false, customerVisible: true },
  ]);
  return <JobCostsEditor value={v} onChange={setV} />;
}

describe("decimal entry in numeric inputs", () => {
  // Re-query after each change — the element reference goes stale when the
  // controlled parent re-renders.
  test("labor 'Drive' bucket keeps a trailing decimal point mid-typing", async () => {
    const { findByLabelText } = await render(<LaborHarness />);
    const drive = () => findByLabelText("Drive hours");

    fireEvent.changeText(await drive(), "0.");
    // The bug: this was forced back to "0". The fix keeps the raw text.
    expect((await drive()).props.value).toBe("0.");

    fireEvent.changeText(await drive(), "0.5");
    expect((await drive()).props.value).toBe("0.5");
  });

  test("direct-cost '$ each' keeps a trailing decimal point mid-typing", async () => {
    const { findByLabelText } = await render(<JobCostsHarness />);
    const each = () => findByLabelText("$ each");

    fireEvent.changeText(await each(), "8.");
    expect((await each()).props.value).toBe("8.");

    fireEvent.changeText(await each(), "8.5");
    expect((await each()).props.value).toBe("8.5");
  });
});
