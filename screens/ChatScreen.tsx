import React, { useState, useCallback, useLayoutEffect, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  KeyboardAvoidingView,
  Platform,
  ActivityIndicator,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { useHeaderHeight } from "@react-navigation/elements";
import { loadSettings } from "../utils/storage";
import { sendGroqMessage, sendClaudeMessage, sendBackendGroqMessage } from "../utils/aiService";
import { getBusinessSnapshot } from "../utils/businessSnapshot";
import { TRADE_TYPES, getTradeNickname } from "../utils/pricingEngine";
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { Ionicons } from "@expo/vector-icons";
import type { Settings } from "../types/models";
import { track, reportError } from '../utils/analytics';

interface LocalMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  isError?: boolean;
}

interface QuickPrompt {
  id: string;
  icon: string;
  label: string;
  text: string;
}

function getQuickPrompts(snapshot: any): QuickPrompt[] {
  const overdue = snapshot?.overdueCount || 0;
  const overdueAmt = snapshot?.overdueTotal || 0;
  const avgJob = snapshot?.avgCompletedJobValue || 0;
  return [
    {
      id: "month",
      icon: "trending-up-outline",
      label: "How's my month?",
      text: "Give me a summary of how my business is performing this month — revenue, outstanding invoices, and any key recommendations.",
    },
    {
      id: "unpaid",
      icon: "wallet-outline",
      label: "Who owes me?",
      text: "Who are my unpaid customers and how should I prioritize following up with them?",
    },
    overdue > 0
      ? {
          id: "overdue",
          icon: "alert-circle-outline",
          label: "Follow up on overdue",
          text: `I have ${overdue} overdue invoice${overdue === 1 ? "" : "s"} totaling $${overdueAmt.toFixed(0)}. Write a professional but firm follow-up message I can send.`,
        }
      : {
          id: "estimate",
          icon: "document-text-outline",
          label: "Write an estimate",
          text: "Help me write a professional estimate to send to a customer.",
        },
    avgJob > 0
      ? {
          id: "profit",
          icon: "bulb-outline",
          label: "Increase job value",
          text: `My average completed job is around $${avgJob.toFixed(0)}. What are practical ways I can increase my average job value and profit margin?`,
        }
      : {
          id: "price",
          icon: "pricetag-outline",
          label: "Price a job",
          text: "I need help pricing a job. What details do you need from me?",
        },
  ];
}

function buildSystemPrompt(s: Partial<Settings>, snapshot: any): string {
  const trade = TRADE_TYPES.find(t => t.id === s.trade)?.label || "Trades";
  const who = [s.businessName, trade, s.contactName].filter(Boolean).join(", ");
  const regionStr = s.region ? ` Region: ${s.region}.` : "";
  let prompt = `Assistant for ${who}.${regionStr} Rates: $${s.laborRate || 85}/hr labor, ${s.materialMarkup || 20}% materials markup, ${s.overheadPercent || 15}% overhead, ${s.marginPercent || 20}% margin, $${s.minimumJobFee || 75} min fee. Be brief. Itemize estimates. USD only.`;

  if (snapshot) {
    const statusLines = Object.entries(snapshot.activeJobsByStatus as Record<string, number>)
      .map(([st, n]) => `${n} ${st.replace("_", " ")}`)
      .join(", ");
    const custLines = (snapshot.topCustomers as any[])
      .map(c => `${c.name} ($${c.lifetimeSpend.toFixed(0)} lifetime${c.amountOwed > 0 ? `, owes $${c.amountOwed.toFixed(0)}` : ""})`)
      .join("; ");
    const overdueStr = snapshot.overdueCount > 0
      ? ` ($${snapshot.overdueTotal.toFixed(0)} overdue, ${snapshot.overdueCount} invoice${snapshot.overdueCount === 1 ? "" : "s"})`
      : "";
    prompt += `\n\nBUSINESS DATA (${snapshot.asOf}):\nRevenue: $${snapshot.revenueThisMonth.toFixed(0)} this month, $${snapshot.revenueLastMonth.toFixed(0)} last month.\nOutstanding: $${snapshot.outstandingTotal.toFixed(0)}${overdueStr}.\nActive jobs: ${statusLines || "none"}.\nCustomers: ${snapshot.totalCustomers} total${custLines ? `. Top: ${custLines}` : ""}.\n${snapshot.avgCompletedJobValue > 0 ? `Avg completed job: $${snapshot.avgCompletedJobValue.toFixed(0)}.` : ""}`.trim();
  }

  return prompt;
}

export default function ChatScreen({ navigation }: { navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [messages, setMessages] = useState<LocalMessage[]>([]);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [snapshot, setSnapshot] = useState<any>(null);
  const headerHeight = useHeaderHeight();

  useLayoutEffect(() => {
    navigation.setOptions({
      title: getTradeNickname(settings?.trade),
      headerRight: () =>
        messages.length > 0 ? (
          <TouchableOpacity onPress={() => setMessages([])} style={{ marginRight: 4 }}>
            <Text style={{ color: colors.accent, fontSize: fontSize.md }}>New chat</Text>
          </TouchableOpacity>
        ) : null,
    });
  }, [navigation, messages.length, settings?.trade, colors.accent]);

  useFocusEffect(
    useCallback(() => {
      loadSettings().then(setSettings);
      getBusinessSnapshot().then(setSnapshot).catch(() => {});
    }, [])
  );

  async function send(overrideText?: string) {
    const text = (overrideText ?? input).trim();
    if (!text || sending) return;
    track('ai_chat_sent');
    setInput("");

    const userMsg: LocalMessage = { id: String(Date.now()), role: "user", text };
    const history = [...messages, userMsg];
    setMessages(history);
    setSending(true);

    try {
      const systemPrompt = buildSystemPrompt(settings || {}, snapshot);
      let reply: string;
      if (settings?.anthropicKey) {
        reply = await sendClaudeMessage({ messages: history, systemPrompt, apiKey: settings.anthropicKey });
      } else if (settings?.groqKey) {
        reply = await sendGroqMessage({ messages: history, systemPrompt, apiKey: settings.groqKey });
      } else {
        reply = await sendBackendGroqMessage({ messages: history, systemPrompt });
      }
      setMessages(prev => [...prev, { id: String(Date.now()) + "r", role: "assistant", text: reply }]);
    } catch (err: unknown) {
      reportError(err, { context: 'aiChat' });
      const msg = (err as Error).message || "";
      setMessages(prev => [
        ...prev,
        {
          id: String(Date.now()) + "e",
          role: "assistant",
          text: `Something went wrong: ${msg}`,
          isError: true,
        },
      ]);
    } finally {
      setSending(false);
    }
  }

  const isEmpty = messages.length === 0 && !sending;

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === "ios" ? "padding" : "height"}
        keyboardVerticalOffset={headerHeight}
      >
        {isEmpty ? (
          <EmptyState onQuickPrompt={send} snapshot={snapshot} />
        ) : (
          <FlatList
            data={[...messages].reverse()}
            keyExtractor={m => m.id}
            inverted
            contentContainerStyle={styles.listContent}
            showsVerticalScrollIndicator={false}
            keyboardShouldPersistTaps="handled"
            renderItem={({ item }) => <Bubble message={item} />}
            ListFooterComponent={
              sending ? (
                <View style={[styles.bubbleRow, styles.bubbleRowAI]}>
                  <View style={[styles.bubble, styles.aiBubble, styles.typingBubble]}>
                    <ActivityIndicator size="small" color={colors.textMuted} />
                  </View>
                </View>
              ) : null
            }
          />
        )}

        <View style={styles.inputRow}>
          <TextInput
            style={styles.textInput}
            value={input}
            onChangeText={setInput}
            placeholder="Ask anything..."
            placeholderTextColor={colors.textMuted}
            accessibilityLabel="Chat message input"
            multiline
            maxLength={2000}
            returnKeyType="default"
          />
          <TouchableOpacity
            style={[styles.sendBtn, (!input.trim() || sending) && styles.sendBtnDisabled]}
            onPress={() => send()}
            disabled={!input.trim() || sending}
            activeOpacity={0.8}
            accessibilityRole="button"
            accessibilityLabel="Send message"
            accessibilityState={{ disabled: !input.trim() || sending }}
          >
            <Text style={styles.sendBtnText}>↑</Text>
          </TouchableOpacity>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

function EmptyState({ onQuickPrompt, snapshot }: { onQuickPrompt: (text: string) => void; snapshot: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const prompts = getQuickPrompts(snapshot);
  return (
    <View style={styles.emptyWrap}>
      <Text style={styles.emptyTitle}>AI Business Advisor</Text>
      <Text style={styles.emptySubtitle}>
        Ask about your revenue, jobs, customers, or anything else about running your business.
      </Text>
      <View style={styles.quickGrid}>
        {prompts.map(qp => (
          <TouchableOpacity
            key={qp.id}
            style={styles.quickBtn}
            onPress={() => onQuickPrompt(qp.text)}
            activeOpacity={0.75}
          >
            <View style={styles.quickBtnInner}>
              <Ionicons name={qp.icon as any} size={18} color={colors.accent} style={styles.quickBtnIcon} />
              <Text style={styles.quickBtnText}>{qp.label}</Text>
            </View>
          </TouchableOpacity>
        ))}
      </View>
    </View>
  );
}

function Bubble({ message }: { message: LocalMessage }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const isUser = message.role === "user";
  return (
    <View style={[styles.bubbleRow, isUser ? styles.bubbleRowUser : styles.bubbleRowAI]}>
      <View style={[styles.bubble, isUser ? styles.userBubble : styles.aiBubble, message.isError && styles.errorBubble]}>
        <Text style={[styles.bubbleText, isUser ? styles.userText : styles.aiText]}>{message.text}</Text>
      </View>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    flex: { flex: 1 },
    emptyWrap: { flex: 1, padding: spacing.lg, paddingTop: 48, alignItems: "center" },
    emptyTitle: { fontSize: fontSize.xl, fontWeight: "700", color: colors.textPrimary, marginBottom: spacing.sm },
    emptySubtitle: { fontSize: fontSize.md, color: colors.textSecondary, textAlign: "center", lineHeight: 22, marginBottom: spacing.xl },
    quickGrid: { width: "100%", gap: spacing.sm },
    quickBtn: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, ...shadow.card },
    quickBtnInner: { flexDirection: "row", alignItems: "center" },
    quickBtnIcon: { marginRight: spacing.sm },
    quickBtnText: { fontSize: fontSize.md, color: colors.accent, fontWeight: "500" },
    listContent: { padding: spacing.md, paddingBottom: spacing.sm },
    bubbleRow: { marginBottom: spacing.sm, flexDirection: "row" },
    bubbleRowUser: { justifyContent: "flex-end" },
    bubbleRowAI: { justifyContent: "flex-start" },
    bubble: { maxWidth: "82%", borderRadius: radius.lg, paddingHorizontal: spacing.md, paddingVertical: 10 },
    userBubble: { backgroundColor: colors.accent },
    aiBubble: { backgroundColor: colors.surface, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, ...shadow.card },
    errorBubble: { backgroundColor: colors.dangerBg, borderColor: colors.danger + "80" },
    typingBubble: { paddingVertical: 12 },
    bubbleText: { fontSize: fontSize.md, lineHeight: 22 },
    userText: { color: "#fff" },
    aiText: { color: colors.textPrimary },
    inputRow: { flexDirection: "row", alignItems: "flex-end", gap: spacing.sm, padding: spacing.sm, paddingBottom: spacing.md, backgroundColor: colors.surface, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border },
    textInput: { flex: 1, backgroundColor: colors.background, borderRadius: radius.lg, paddingHorizontal: spacing.md, paddingTop: 10, paddingBottom: 10, fontSize: fontSize.md, color: colors.textPrimary, maxHeight: 120, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
    sendBtn: { width: 40, height: 40, borderRadius: 20, backgroundColor: colors.accent, alignItems: "center", justifyContent: "center" },
    sendBtnDisabled: { backgroundColor: colors.border },
    sendBtnText: { color: "#fff", fontSize: 22, fontWeight: "700", lineHeight: 24 },
  });
}
