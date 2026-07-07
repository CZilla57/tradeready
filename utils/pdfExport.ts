import * as Print from "expo-print";
import * as Sharing from "expo-sharing";
import { Alert } from "react-native";

export async function exportPdf(html: string, filename = "document"): Promise<void> {
  try {
    const { uri } = await Print.printToFileAsync({ html });
    const available = await Sharing.isAvailableAsync();
    if (!available) {
      Alert.alert("Sharing not available", "This device cannot share files.");
      return;
    }
    await Sharing.shareAsync(uri, {
      mimeType: "application/pdf",
      dialogTitle: `${filename}.pdf`,
      UTI: "com.adobe.pdf",
    });
  } catch {
    Alert.alert("PDF error", "Could not generate PDF. Please try again.");
  }
}
