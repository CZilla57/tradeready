// screens/ChatScreen.js
// AI chatbot powered by Groq — helps with estimates, business advice,
// and drafting messages to customers.

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
import { sendGroqMessage, sendClaudeMessage } from "../utils/aiService";
import { getBusinessSnapshot } from "../utils/businessSnapshot";
import { TRADE_TYPES, getTradeNickname } from "../utils/pricingEngine";
import { spacing, radius, fontSize } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';

function getQuickPrompts(snapshot) {
  const overdue = snapshot?.overdueCount || 0;
  const overdueAmt = snapshot?.overdueTotal || 0;
  const avgJob = snapshot?.avgCompletedJobValue || 0;
  return [
    {
      id: "month",
      label: "📈  How's my month?",
      text: "Give me a summary of how my business is performing this month — revenue, outstanding invoices, and any key recommendations.",
    },
    {
      id: "unpaid",
      label: "💸  Who owes me?",
      text: "Who are my unpaid customers and how should I prioritize following up with them?",
    },
    overdue > 0
      ? {
          id: "overdue",
          label: `⚠️  Follow up on overdue`,
          text: `I have ${overdue} overdue invoice${overdue === 1 ? "" : "s"} totaling $${overdueAmt.toFixed(0)}. Write a professional but firm follow-up message I can send.`,
        }
      : {
          id: "estimate",
          label: "📋  Write an estimate",
          text: "Help me write a professional estimate to send to a customer.",
        },
    avgJob > 0
      ? {
          id: "profit",
          label: "💡  Increase job value",
          text: `My average completed job is around $${avgJob.toFixed(0)}. What are practical ways I can increase my average job value and profit margin?`,
        }
      : {
          id: "price",
          label: "💰  Price a job",
          text: "I need help pricing a job. What details do you need from me?",
        },
  ];
}

function buildSystemPrompt(s, snapshot) {
  const trade = TRADE_TYPES.find(t => t.id === s.trade)?.label || "Trades";
  const who = [s.businessName, trade, s.contactName].filter(Boolean).join(", ");
  let prompt = `Assistant for ${who}. Rates: $${s.laborRate || 85}/hr labor, ${s.materialMarkup || 20}% materials markup, ${s.overheadPercent || 15}% overhead, ${s.marginPercent || 20}% margin, $${s.minimumJobFee || 75} min fee. Be brief. Itemize estimates. USD only.`;

  if (snapshot) {
    const statusLines = Object.entries(snapshot.activeJobsByStatus)
      .map(([st, n]) => `${n} ${st.replace("_", " ")}`)
      .join(", ");
    const custLines = snapshot.topCustomers
      .map(c => `${c.name} ($${c.lifetimeSpend.toFixed(0)} lifetime${c.amountOwed > 0 ? `, owes $${c.amountOwed.toFixed(0)}` : ""})`)
      .join("; ");
    const overdueStr = snapshot.overdueCount > 0
      ? ` ($${snapshot.overdueTotal.toFixed(0)} overdue, ${snapshot.overdueCount} invoice${snapshot.overdueCount === 1 ? "" : "s"})`
      : "";

    prompt += `\n\nBUSINESS DATA (${snapshot.asOf}):\nRevenue: $${snapshot.revenueThisMonth.toFixed(0)} this month, $${snapshot.revenueLastMonth.toFixed(0)} last month.\nOutstanding: $${snapshot.outstandingTotal.toFixed(0)}${overdueStr}.\nActive jobs: ${statusLines || "none"}.\nCustomers: ${snapshot.totalCustomers} total${custLines ? `. Top: ${custLines}` : ""}.\n${snapshot.avgCompletedJobValue > 0 ? `Avg completed job: $${snapshot.avgCompletedJobValue.toFixed(0)}.` : ""}`.trim();
  }

  return prompt;
}

export default function ChatScreen({ navigation }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [settings, setSettings] = useState(null);
  const [snapshot, setSnapshot] = useState(null);
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
  }, [navigation, messages.length, settings?.trade]);

  useFocusEffect(
    useCallback(() => {
      loadSettings().then(setSettings);
      getBusinessSnapshot().then(setSnapshot).catch(() => {});
    }, [])
  );

  async function send(overrideText) {
    const text = (overrideText ?? input).trim();
    if (!text || sending) return;
    setInput("");

    const userMsg = { id: String(Date.now()), role: "user", text };
    const history = [...messages, userMsg];
    setMessages(history);
    setSending(true);

    try {
      const systemPrompt = buildSystemPrompt(settings || {}, snapshot);
      const reply = settings?.anthropicKey
        ? await sendClaudeMessage({ messages: history, systemPrompt, apiKey: settings.anthropicKey })
        : await sendGroqMessage({ messages: history, systemPrompt, apiKey: settings?.groqKey });
      setMessages(prev => [...prev, { id: String(Date.now()) + "r", role: "assistant", text: reply }]);
    } catch (err) {
      const isNoKey = err.message.includes("No AI key");
      setMessages(prev => [
        ...prev,
        {
          id: String(Date.now()) + "e",
          role: "assistant",
          text: isNoKey
            ? "Add your Groq or Anthropic API key in Settings → AI Assistant to get started."
            : `Something went wrong: ${err.message}`,
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
            multiline
            maxLength={2000}
            returnKeyType="default"
          />
          <TouchableOpacity
            style={[styles.sendBtn, (!input.trim() || sending) && styles.sendBtnDisabled]}
            onPress={() => send()}
            disabled={!input.trim() || sending}
            activeOpacity={0.8}
          >
            <Text style={styles.sendBtnText}>↑</Text>
          </TouchableOpacity>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

function EmptyState({ onQuickPrompt, snapshot }) {
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
            <Text style={styles.quickBtnText}>{qp.label}</Text>
          </TouchableOpacity>
        ))}
      </View>
    </View>
  );
}

function Bubble({ message }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const isUser = message.role === "user";
  return (
    <View style={[styles.bubbleRow, isUser ? styles.bubbleRowUser : styles.bubbleRowAI]}>
      <View style={[
        styles.bubble,
        isUser ? styles.userBubble : styles.aiBubble,
        message.isError && styles.errorBubble,
      ]}>
        <Text style={[styles.bubbleText, isUser ? styles.userText : styles.aiText]}>
          {message.text}
        </Text>
      </View>
    </View>
  );
}

function createStyles(colors, shadow) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    flex: { flex: 1 },

    // Empty / quick-start
    emptyWrap: {
      flex: 1,
      padding: spacing.lg,
      paddingTop: 48,
      alignItems: "center",
    },
    emptyTitle: {
      fontSize: fontSize.xl,
      fontWeight: "700",
      color: colors.textPrimary,
      marginBottom: spacing.sm,
    },
    emptySubtitle: {
      fontSize: fontSize.md,
      color: colors.textSecondary,
      textAlign: "center",
      lineHeight: 22,
      marginBottom: spacing.xl,
    },
    quickGrid: { width: "100%", gap: spacing.sm },
    quickBtn: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      padding: spacing.md,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
      ...shadow.card,
    },
    quickBtnText: {
      fontSize: fontSize.md,
      color: colors.accent,
      fontWeight: "500",
    },

    // Messages
    listContent: { padding: spacing.md, paddingBottom: spacing.sm },
    bubbleRow: { marginBottom: spacing.sm, flexDirection: "row" },
    bubbleRowUser: { justifyContent: "flex-end" },
    bubbleRowAI: { justifyContent: "flex-start" },
    bubble: {
      maxWidth: "82%",
      borderRadius: radius.lg,
      paddingHorizontal: spacing.md,
      paddingVertical: 10,
    },
    userBubble: { backgroundColor: colors.accent },
    aiBubble: {
      backgroundColor: colors.surface,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
      ...shadow.card,
    },
    errorBubble: { backgroundColor: colors.dangerBg, borderColor: colors.danger + "80" },
    typingBubble: { paddingVertical: 12 },
    bubbleText: { fontSize: fontSize.md, lineHeight: 22 },
    userText: { color: "#fff" },
    aiText: { color: colors.textPrimary },

    // Input bar
    inputRow: {
      flexDirection: "row",
      alignItems: "flex-end",
      gap: spacing.sm,
      padding: spacing.sm,
      paddingBottom: spacing.md,
      backgroundColor: colors.surface,
      borderTopWidth: StyleSheet.hairlineWidth,
      borderTopColor: colors.border,
    },
    textInput: {
      flex: 1,
      backgroundColor: colors.background,
      borderRadius: radius.lg,
      paddingHorizontal: spacing.md,
      paddingTop: 10,
      paddingBottom: 10,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      maxHeight: 120,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
    },
    sendBtn: {
      width: 40,
      height: 40,
      borderRadius: 20,
      backgroundColor: colors.accent,
      alignItems: "center",
      justifyContent: "center",
    },
    sendBtnDisabled: { backgroundColor: colors.border },
    sendBtnText: { color: "#fff", fontSize: 22, fontWeight: "700", lineHeight: 24 },
  });
}
