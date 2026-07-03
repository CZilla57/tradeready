// screens/ChatScreen.js
// AI chatbot powered by Gemini — helps with estimates, business advice,
// and drafting messages to customers.

import React, { useState, useCallback, useLayoutEffect } from "react";
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
import { sendGeminiMessage } from "../utils/aiService";
import { TRADE_TYPES, getTradeNickname } from "../utils/pricingEngine";
import { colors, spacing, radius, fontSize, shadow } from "../utils/theme";

const QUICK_PROMPTS = [
  { id: "price",    label: "💰  Price a job",         text: "I need help pricing a job. What details do you need from me?" },
  { id: "invoice",  label: "📩  Invoice message",      text: "Help me write a professional message to a customer about an unpaid invoice." },
  { id: "estimate", label: "📋  Write an estimate",    text: "Help me write a professional estimate to send to a customer." },
  { id: "advice",   label: "💡  Business advice",      text: "Give me practical tips for running a more profitable trades business." },
];

function buildSystemPrompt(s) {
  const trade = TRADE_TYPES.find(t => t.id === s.trade)?.label || "Trades";
  const who = [s.businessName, trade, s.contactName].filter(Boolean).join(", ");
  return `Assistant for ${who}. Rates: $${s.laborRate || 85}/hr labor, ${s.materialMarkup || 20}% materials markup, ${s.overheadPercent || 15}% overhead, ${s.marginPercent || 20}% margin, $${s.minimumJobFee || 75} min fee. Be brief. Itemize estimates. USD only.`;
}

export default function ChatScreen({ navigation }) {
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [settings, setSettings] = useState(null);
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
      const reply = await sendGeminiMessage({
        messages: history,
        systemPrompt: buildSystemPrompt(settings || {}),
        apiKey: settings?.geminiKey,
      });
      setMessages(prev => [...prev, { id: String(Date.now()) + "r", role: "assistant", text: reply }]);
    } catch (err) {
      const isNoKey = err.message.includes("No Gemini");
      setMessages(prev => [
        ...prev,
        {
          id: String(Date.now()) + "e",
          role: "assistant",
          text: isNoKey
            ? "Add your free Gemini API key in Settings → AI Assistant to get started."
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
          <EmptyState onQuickPrompt={send} />
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

function EmptyState({ onQuickPrompt }) {
  return (
    <View style={styles.emptyWrap}>
      <Text style={styles.emptyTitle}>AI Assistant</Text>
      <Text style={styles.emptySubtitle}>
        Ask anything about pricing, customers, or running your business.
      </Text>
      <View style={styles.quickGrid}>
        {QUICK_PROMPTS.map(qp => (
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

const styles = StyleSheet.create({
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
