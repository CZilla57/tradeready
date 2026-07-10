import React, { useEffect, useRef, useState } from 'react';
import { Animated, View, Text, TouchableOpacity, ActivityIndicator, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useSyncStatusContext } from '../context/SyncStatusContext';
import { useThemeContext } from '../context/ThemeContext';

export function SyncBanner() {
  const { isOnline, pendingCount, syncing, syncNow } = useSyncStatusContext();
  const { colors } = useThemeContext();
  const insets = useSafeAreaInsets();

  const visible = !isOnline || pendingCount > 0;
  const translateY = useRef(new Animated.Value(visible ? 0 : -100)).current;
  // Keep the banner mounted while its hide animation plays, but unmount it
  // (no rendered content) once fully hidden — otherwise offline/pending
  // text would linger in the tree even when the banner is off-screen.
  const [mounted, setMounted] = useState(visible);

  useEffect(() => {
    if (visible) {
      setMounted(true);
    }
    Animated.timing(translateY, {
      toValue: visible ? 0 : -100,
      duration: 300,
      useNativeDriver: true,
    }).start(({ finished }) => {
      if (finished && !visible) {
        setMounted(false);
      }
    });
  }, [visible, translateY]);

  if (!mounted) {
    return null;
  }

  const isOffline = !isOnline;
  const bgColor = isOffline ? colors.dangerBg : colors.warningBg;
  const accentColor = isOffline ? colors.danger : colors.warning;

  const icon = isOffline ? 'cloud-offline-outline' : 'cloud-upload-outline';
  const message = isOffline ? "You're offline" : `${pendingCount} change${pendingCount === 1 ? '' : 's'} pending`;

  return (
    <Animated.View
      style={[
        styles.container,
        {
          transform: [{ translateY }],
          paddingTop: insets.top + 4,
          backgroundColor: bgColor,
          borderBottomColor: accentColor,
        },
      ]}
      pointerEvents={visible ? 'auto' : 'none'}
    >
      <View style={styles.content}>
        <Ionicons name={icon as any} size={18} color={accentColor} />
        <Text style={[styles.text, { color: colors.textPrimary }]}>{message}</Text>
        {isOnline && pendingCount > 0 && (
          syncing ? (
            <ActivityIndicator size="small" color={accentColor} testID="sync-spinner" />
          ) : (
            <TouchableOpacity onPress={syncNow} style={[styles.button, { backgroundColor: accentColor }]}>
              <Text style={styles.buttonText}>Sync Now</Text>
            </TouchableOpacity>
          )
        )}
      </View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    borderBottomWidth: 1,
    zIndex: 999,
  },
  content: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 16,
    paddingBottom: 8,
    gap: 8,
  },
  text: {
    fontSize: 14,
    fontWeight: '600',
  },
  button: {
    minHeight: 44,
    justifyContent: 'center',
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 4,
  },
  buttonText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '700',
  },
});
