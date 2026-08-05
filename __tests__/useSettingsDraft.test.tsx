// __tests__/useSettingsDraft.test.tsx
// The extracted Settings draft contract: load→draft, flushed dirty check,
// header Save (validate, save, onSaved), the beforeRemove guard's three
// outcomes (clean pass-through, Discard, Save-without-validate), and the
// tab-switch blur pop.
import React from "react";
import { Alert, Text, TextInput, TouchableOpacity, View } from "react-native";
import { render, fireEvent, waitFor, act } from "@testing-library/react-native";
import { useSettingsDraft, type SettingsDraftOptions } from "../hooks/useSettingsDraft";
import { loadSettings, saveSettings } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { defaultSettings } from "../utils/storage/defaults";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));

function makeNavigation() {
  const listeners: Record<string, ((e?: any) => void)[]> = {};
  const nav = {
    setOptions: jest.fn(),
    addListener: jest.fn((type: string, cb: (e?: any) => void) => {
      (listeners[type] = listeners[type] ?? []).push(cb);
      return jest.fn();
    }),
    getParent: jest.fn(() => ({
      getState: () => ({ index: 0, routes: [{ name: "Today" }] }),
    })),
    popToTop: jest.fn(),
    dispatch: jest.fn(),
  } as any;
  return { nav, listeners };
}

function Harness({ navigation, options }: { navigation: any; options?: SettingsDraftOptions }) {
  const { s, update, dirty, handleSave } = useSettingsDraft(navigation, options);
  if (!s) return null;
  return (
    <View>
      <Text testID="dirty">{dirty ? "dirty" : "clean"}</Text>
      <TextInput
        accessibilityLabel="Business name"
        value={s.businessName}
        onChangeText={(v) => update("businessName", v)}
      />
      <TouchableOpacity accessibilityLabel="Save now" onPress={handleSave}>
        <Text>Save now</Text>
      </TouchableOpacity>
    </View>
  );
}

function removalEvent() {
  return { preventDefault: jest.fn(), data: { action: { type: "POP" } } };
}

describe("useSettingsDraft", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("loads settings into a clean draft and registers a header Save", async () => {
    const { nav } = makeNavigation();
    const { findByTestId } = await render(<Harness navigation={nav} />);
    expect((await findByTestId("dirty")).props.children).toBe("clean");
    const lastOpts = (nav.setOptions as jest.Mock).mock.calls.at(-1)[0];
    expect(typeof lastOpts.headerRight).toBe("function");
  });

  it("prepare massages the loaded settings before they become the draft", async () => {
    const { nav } = makeNavigation();
    const options: SettingsDraftOptions = {
      prepare: (loaded) => ({ ...loaded, businessName: "Prepared Co" }),
    };
    const { findByLabelText } = await render(<Harness navigation={nav} options={options} />);
    expect((await findByLabelText("Business name")).props.value).toBe("Prepared Co");
  });

  it("an edit makes the draft dirty; a save makes it clean and persists", async () => {
    const { nav } = makeNavigation();
    const onSaved = jest.fn();
    const { findByLabelText, getByTestId, getByLabelText } = await render(
      <Harness navigation={nav} options={{ onSaved }} />
    );
    await fireEvent.changeText(await findByLabelText("Business name"), "Acme Plumbing");
    expect(getByTestId("dirty").props.children).toBe("dirty");

    await fireEvent.press(getByLabelText("Save now"));
    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({ businessName: "Acme Plumbing" })
    );
    expect(syncNotifications).toHaveBeenCalledTimes(1);
    expect(onSaved).toHaveBeenCalledWith(
      expect.objectContaining({ businessName: "Acme Plumbing" })
    );
    await waitFor(() => expect(getByTestId("dirty").props.children).toBe("clean"));
  });

  it("validate problems block the header save with an alert", async () => {
    const { nav } = makeNavigation();
    const options: SettingsDraftOptions = { validate: () => ["Bad value."] };
    const { findByLabelText, getByLabelText } = await render(
      <Harness navigation={nav} options={options} />
    );
    await fireEvent.changeText(await findByLabelText("Business name"), "x");
    await fireEvent.press(getByLabelText("Save now"));
    await waitFor(() =>
      expect(Alert.alert).toHaveBeenCalledWith("Fix before saving", "Bad value.")
    );
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it("flush folds page-local drafts into dirty checks and saves", async () => {
    const { nav } = makeNavigation();
    const options: SettingsDraftOptions = {
      flush: (s) => (s.businessName.endsWith("!") ? s : { ...s, businessName: s.businessName + "!" }),
    };
    const { findByTestId, getByTestId, getByLabelText } = await render(
      <Harness navigation={nav} options={options} />
    );
    // flush alone makes the flushed draft differ from the snapshot.
    expect((await findByTestId("dirty")).props.children).toBe("dirty");
    await fireEvent.press(getByLabelText("Save now"));
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({ businessName: expect.stringMatching(/!$/) })
      )
    );
    await waitFor(() => expect(getByTestId("dirty").props.children).toBe("clean"));
  });

  it("beforeRemove passes a clean draft through untouched", async () => {
    const { nav, listeners } = makeNavigation();
    const { findByTestId } = await render(<Harness navigation={nav} />);
    expect((await findByTestId("dirty")).props.children).toBe("clean");
    const e = removalEvent();
    listeners["beforeRemove"][0](e);
    expect(e.preventDefault).not.toHaveBeenCalled();
  });

  it("beforeRemove on a dirty draft prompts; Discard fires onDiscarded and resumes", async () => {
    const { nav, listeners } = makeNavigation();
    const onDiscarded = jest.fn();
    const { findByLabelText } = await render(
      <Harness navigation={nav} options={{ onDiscarded }} />
    );
    await fireEvent.changeText(await findByLabelText("Business name"), "Dirty Co");

    const e = removalEvent();
    listeners["beforeRemove"][0](e);
    expect(e.preventDefault).toHaveBeenCalled();

    const buttons = (Alert.alert as jest.Mock).mock.calls.at(-1)[2];
    const discard = buttons.find((b: any) => b.text === "Discard");
    discard.onPress();
    expect(onDiscarded).toHaveBeenCalledTimes(1);
    expect(nav.dispatch).toHaveBeenCalledWith(e.data.action);
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it("guard-Save saves WITHOUT validate, fires onSaved, and resumes", async () => {
    const { nav, listeners } = makeNavigation();
    const validate = jest.fn(() => ["Would block."]);
    const onSaved = jest.fn();
    const { findByLabelText } = await render(
      <Harness navigation={nav} options={{ validate, onSaved }} />
    );
    await fireEvent.changeText(await findByLabelText("Business name"), "Guarded Co");

    const e = removalEvent();
    listeners["beforeRemove"][0](e);
    const buttons = (Alert.alert as jest.Mock).mock.calls.at(-1)[2];
    const save = buttons.find((b: any) => b.text === "Save");
    await act(async () => {
      await save.onPress();
    });

    expect(validate).not.toHaveBeenCalled(); // the pinned asymmetry
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({ businessName: "Guarded Co" })
    );
    expect(onSaved).toHaveBeenCalledTimes(1);
    expect(nav.dispatch).toHaveBeenCalledWith(e.data.action);
  });

  it("blur pops to top only when the active tab is not Today", async () => {
    const { nav, listeners } = makeNavigation();
    await render(<Harness navigation={nav} />);

    listeners["blur"][0]();
    expect(nav.popToTop).not.toHaveBeenCalled(); // active tab is Today

    (nav.getParent as jest.Mock).mockReturnValue({
      getState: () => ({ index: 1, routes: [{ name: "Today" }, { name: "Jobs" }] }),
    });
    listeners["blur"][0]();
    expect(nav.popToTop).toHaveBeenCalledTimes(1);
  });
});
