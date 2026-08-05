// screens/SettingsAccountScreen.tsx
// Immediate-action page: Clear Sample Data / Sign Out / Delete Account all
// act on tap, never through a draft — so this page has NO draft hook
// (useSettingsDraft), only useSettingsTabPop. A page that can reset the
// entire local dataset must never be able to trip an unsaved-edits guard,
// so there is no suppressDirtyWarnRef here at all.
import React, { useState, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Modal,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import Constants from "expo-constants";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { clearSampleData, clearAllUserData } from "../utils/storage";
import { syncIfOnline } from "../utils/sync";
import { supabase } from "../utils/supabase";
import { resetUser, reportError } from "../utils/analytics";
import { useSyncStatusContext } from "../context/SyncStatusContext";
import { DELETE_CONFIRM_PHRASE, deleteConfirmMatches } from "../utils/deleteConfirm";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

const VERCEL_URL = Constants.expoConfig?.extra?.backendUrl ?? "";

export default function SettingsAccountScreen({ navigation }: TodayStackScreenProps<'SettingsAccount'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  useSettingsTabPop(navigation);

  const [deleting, setDeleting] = useState(false);
  const [deleteModalVisible, setDeleteModalVisible] = useState(false);
  const [deleteConfirmText, setDeleteConfirmText] = useState("");
  const { pendingCount } = useSyncStatusContext();

  async function performDeleteAccount() {
    setDeleting(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) { Alert.alert("Error", "No active session. Please sign in again."); return; }
      const res = await fetch(`${VERCEL_URL}/api/delete-account`, {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || "Failed to delete account.");
      }
      resetUser();
      await clearAllUserData();
      await supabase.auth.signOut();
    } catch (err: unknown) {
      reportError(err, { context: 'deleteAccount' });
      Alert.alert("Error", (err as Error).message || "Something went wrong. Please try again.");
    } finally {
      setDeleting(false);
    }
  }

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <TouchableOpacity
          style={styles.clearSampleBtn}
          accessibilityRole="button"
          accessibilityLabel="Clear sample data"
          onPress={() => Alert.alert("Clear sample data", "This permanently removes all sample customers, jobs, and invoices. Your own data is not affected.", [
            { text: "Cancel", style: "cancel" },
            { text: "Clear sample data", style: "destructive", onPress: async () => { await clearSampleData(); Alert.alert("Done", "Sample data has been removed."); } },
          ])}
        >
          <Text style={styles.clearSampleText}>Clear Sample Data</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={styles.signOutBtn}
          accessibilityRole="button"
          accessibilityLabel="Sign out"
          onPress={() => {
            const doSignOut = async () => { resetUser(); await clearAllUserData(); await supabase.auth.signOut(); };
            if (pendingCount > 0) {
              Alert.alert("Unsynced changes", "You have changes that haven't been saved to the cloud yet. Sync now to keep them.", [
                { text: "Cancel", style: "cancel" },
                { text: "Sync & sign out", onPress: async () => { const { data: { session } } = await supabase.auth.getSession(); if (session?.user?.id) await syncIfOnline(session.user.id); await doSignOut(); } },
                { text: "Sign out anyway", style: "destructive", onPress: doSignOut },
              ]);
            } else {
              Alert.alert("Sign out", "Are you sure you want to sign out?", [
                { text: "Cancel", style: "cancel" },
                { text: "Sign out", style: "destructive", onPress: doSignOut },
              ]);
            }
          }}
        >
          <Text style={styles.signOutText}>Sign Out</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.deleteAccountBtn, deleting && { opacity: 0.5 }]}
          disabled={deleting}
          accessibilityRole="button"
          accessibilityLabel="Delete account"
          accessibilityState={{ disabled: deleting, busy: deleting }}
          onPress={() => { setDeleteConfirmText(""); setDeleteModalVisible(true); }}
        >
          <Text style={styles.deleteAccountText}>{deleting ? "Deleting account…" : "Delete Account"}</Text>
        </TouchableOpacity>
      </ScrollView>

      <Modal
        visible={deleteModalVisible}
        transparent
        animationType="fade"
        onRequestClose={() => setDeleteModalVisible(false)}
      >
        <KeyboardAvoidingView
          style={styles.modalBackdrop}
          behavior={Platform.OS === "ios" ? "padding" : undefined}
        >
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle} accessibilityRole="header">Delete account</Text>
            <Text style={styles.modalBody}>
              This permanently deletes your account and all your data — jobs, invoices,
              customers, and expenses. This cannot be undone.
            </Text>
            <Text style={styles.modalBody}>Type {DELETE_CONFIRM_PHRASE} to confirm.</Text>
            <TextInput
              style={styles.input}
              value={deleteConfirmText}
              onChangeText={setDeleteConfirmText}
              placeholder={DELETE_CONFIRM_PHRASE}
              placeholderTextColor={colors.textMuted}
              autoCapitalize="characters"
              autoCorrect={false}
              returnKeyType="done"
              accessibilityLabel={`Type ${DELETE_CONFIRM_PHRASE} to confirm account deletion`}
            />
            <View style={styles.modalBtnRow}>
              <TouchableOpacity
                style={styles.modalCancelBtn}
                onPress={() => setDeleteModalVisible(false)}
                accessibilityRole="button"
                accessibilityLabel="Cancel"
              >
                <Text style={styles.modalCancelText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.modalDeleteBtn, !deleteConfirmMatches(deleteConfirmText) && { opacity: 0.5 }]}
                disabled={!deleteConfirmMatches(deleteConfirmText)}
                onPress={() => { setDeleteModalVisible(false); performDeleteAccount(); }}
                accessibilityRole="button"
                accessibilityLabel="Delete my account"
                accessibilityState={{ disabled: !deleteConfirmMatches(deleteConfirmText) }}
              >
                <Text style={styles.modalDeleteText}>Delete my account</Text>
              </TouchableOpacity>
            </View>
          </View>
        </KeyboardAvoidingView>
      </Modal>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    input: { fontFamily: fonts.bodyRegular, backgroundColor: colors.background, borderRadius: radius.md, minHeight: 44, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
    clearSampleBtn: { marginTop: spacing.lg, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    clearSampleText: { fontFamily: fonts.bodyMedium, color: colors.textSecondary, fontSize: fontSize.md },
    signOutBtn: { marginTop: spacing.sm, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.danger + "50", backgroundColor: colors.dangerBg },
    signOutText: { fontFamily: fonts.bodySemiBold, color: colors.danger, fontSize: fontSize.md },
    deleteAccountBtn: { marginTop: spacing.sm, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, backgroundColor: colors.danger },
    deleteAccountText: { fontFamily: fonts.bodySemiBold, color: "#fff", fontSize: fontSize.md },
    modalBackdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.5)", justifyContent: "center", padding: spacing.lg },
    // Centred alert-style card (the backdrop insets it with `padding`, not a
    // margin, so the column token composes safely here). Keeps the card from
    // spanning the full iPad window; a no-op below 700pt.
    modalCard: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.lg, ...shadow.card, ...layout.contentColumn },
    modalTitle: { fontFamily: fonts.display, fontSize: fontSize.lg, color: colors.textPrimary, marginBottom: spacing.sm },
    modalBody: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    modalBtnRow: { flexDirection: "row", justifyContent: "flex-end", gap: 12, marginTop: spacing.md },
    modalCancelBtn: { minHeight: 44, justifyContent: "center", paddingHorizontal: 16, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border },
    modalCancelText: { fontFamily: fonts.bodyMedium, color: colors.textPrimary, fontSize: fontSize.md },
    modalDeleteBtn: { minHeight: 44, justifyContent: "center", paddingHorizontal: 16, borderRadius: radius.md, backgroundColor: colors.danger },
    modalDeleteText: { fontFamily: fonts.bodySemiBold, color: "#fff", fontSize: fontSize.md },
  });
}
