// screens/SettingsBookingScreen.tsx
// Booking link is an IMMEDIATE-action page: loadSettings/saveSettings at
// action time, local state, no draft. On the old monolithic screen these
// handlers also had to patch the just-persisted link into the screen's
// `s`/`savedSnapshot` draft so a later "Save settings" wouldn't clobber it
// (the Task-10 data-loss bug). This page has no coexisting draft, so that
// machinery is gone by design — do not reintroduce a draft here.
import React, { useEffect, useMemo, useState } from "react";
import { View, Text, ScrollView, StyleSheet, Switch, TouchableOpacity, Alert, Share } from "react-native";
import { loadSettings, saveSettings } from "../utils/storage";
import { mintBookingToken, buildBookingUrl } from "../utils/bookingLink";
import { reportError } from "../utils/analytics";
import { Button } from "../components/UI";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { Settings } from "../types/models";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsBookingScreen({ navigation }: TodayStackScreenProps<'SettingsBooking'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [bookingLink, setBookingLink] = useState<Settings["bookingLink"] | null>(null);
  const [schedule, setSchedule] = useState<Settings["schedule"] | null>(null);
  const [loaded, setLoaded] = useState(false);
  useSettingsTabPop(navigation);

  useEffect(() => {
    loadSettings().then((l) => {
      setBookingLink(l.bookingLink ?? null);
      setSchedule(l.schedule ?? null);
      setLoaded(true);
    });
  }, []);

  const handleCreateBookingLink = async () => {
    try {
      const out = await mintBookingToken();
      if (!out.ok) { Alert.alert("Couldn't create link", out.message); return; }
      const current = await loadSettings();
      const next = { token: out.token, enabled: true };
      await saveSettings({ ...current, bookingLink: next });
      setBookingLink(next);
    } catch (err: unknown) {
      reportError(err, { context: 'bookingLinkCreate' });
      Alert.alert("Couldn't create link", (err as Error).message || "Please try again.");
    }
  };

  const handleToggleBooking = async (enabled: boolean) => {
    try {
      const current = await loadSettings();
      if (!current.bookingLink) return;
      const next = { ...current.bookingLink, enabled };
      await saveSettings({ ...current, bookingLink: next });
      setBookingLink(next);
    } catch (err: unknown) {
      reportError(err, { context: 'bookingLinkToggle' });
      Alert.alert("Couldn't update", (err as Error).message || "Please try again.");
    }
  };

  // Phase 11 C (2026-08-07 spec §7): the slot-booking feature flag. Enabling
  // stamps the device's IANA zone once (kept thereafter; editable later via
  // a deliberate re-enable) — the server needs it to resolve naive slots to
  // UTC instants. Same immediate-action pattern as the link toggle above.
  const handleToggleSlots = async (enabled: boolean) => {
    try {
      const current = await loadSettings();
      const timeZone =
        current.schedule?.timeZone ||
        Intl.DateTimeFormat().resolvedOptions().timeZone ||
        "UTC";
      const nextSchedule = { ...current.schedule, bookableSlotsEnabled: enabled, timeZone };
      await saveSettings({ ...current, schedule: nextSchedule });
      setSchedule(nextSchedule);
    } catch (err: unknown) {
      reportError(err, { context: 'bookingSlotsToggle' });
      Alert.alert("Couldn't update", (err as Error).message || "Please try again.");
    }
  };

  const handleShareBookingLink = async (token: string) => {
    try {
      await Share.share({ message: buildBookingUrl(token) });
    } catch (err: unknown) {
      reportError(err, { context: 'bookingLinkShare' });
    }
  };

  const handleNewBookingLink = () => {
    Alert.alert(
      "Get a new link?",
      "Your current booking link will stop working immediately. Anywhere you've shared it will show an invalid-link message.",
      [
        { text: "Cancel", style: "cancel" },
        { text: "Get new link", style: "destructive", onPress: () => { void handleCreateBookingLink(); } },
      ]
    );
  };

  if (!loaded) return null;

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <View style={styles.card}>
          {bookingLink ? (
            <>
              <Text style={styles.bookingUrlText} selectable accessibilityLabel="Your booking link">
                {buildBookingUrl(bookingLink.token)}
              </Text>
              <TouchableOpacity
                style={styles.stripeBtn}
                onPress={() => handleShareBookingLink(bookingLink.token)}
                accessibilityRole="button"
                accessibilityLabel="Share link"
              >
                <Text style={styles.stripeBtnText}>Share link</Text>
              </TouchableOpacity>
              <View style={[styles.toggleRow, { marginTop: spacing.md }]}>
                <Text style={styles.toggleLabel}>Accepting requests</Text>
                <Switch
                  value={bookingLink.enabled}
                  onValueChange={(v) => { void handleToggleBooking(v); }}
                  trackColor={{ false: colors.border, true: colors.accent }}
                  accessibilityLabel="Accepting requests"
                />
              </View>
              <View style={styles.toggleRow}>
                <View style={styles.toggleTextWrap}>
                  <Text style={styles.toggleLabel}>Bookable time slots</Text>
                  <Text style={styles.toggleHint}>
                    {schedule?.bookableSlotsEnabled
                      ? `Customers pick from your open slots (${schedule?.timeZone ?? "device timezone"}). Hours live in Settings → Schedule.`
                      : "Off: customers describe their timing in a text box and you schedule from the lead."}
                  </Text>
                </View>
                <Switch
                  value={schedule?.bookableSlotsEnabled === true}
                  onValueChange={(v) => { void handleToggleSlots(v); }}
                  trackColor={{ false: colors.border, true: colors.accent }}
                  accessibilityLabel="Bookable time slots"
                />
              </View>
              <TouchableOpacity
                style={styles.listRow}
                onPress={handleNewBookingLink}
                accessibilityRole="button"
                accessibilityLabel="Get a new link"
              >
                <Text style={styles.listRowText}>Get a new link</Text>
                <Text style={styles.listRowChevron}>›</Text>
              </TouchableOpacity>
            </>
          ) : (
            <>
              <Text style={styles.providerHint}>Share one link; new job requests land in Jobs as leads.</Text>
              <Button label="Create my booking link" onPress={() => { void handleCreateBookingLink(); }} />
            </>
          )}
        </View>
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    providerHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    bookingUrlText: { fontFamily: fonts.mono, fontSize: fontSize.sm, color: colors.textPrimary, marginBottom: spacing.sm },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginTop: spacing.md },
    toggleTextWrap: { flex: 1, marginRight: spacing.sm },
    toggleLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    toggleHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 2 },
    listRow: { flexDirection: "row", alignItems: "center", paddingVertical: 13 },
    listRowText: { fontFamily: fonts.bodyRegular, flex: 1, fontSize: fontSize.md, color: colors.textPrimary },
    listRowChevron: { fontSize: 20, color: colors.textMuted },
    stripeBtn: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.accent, alignItems: "center", justifyContent: "center" },
    stripeBtnText: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.accent },
  });
}
