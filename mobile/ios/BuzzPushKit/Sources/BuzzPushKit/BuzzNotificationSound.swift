import UserNotifications

/// Applies the ordinary alert sound policy at the final service-extension handoff.
public enum BuzzNotificationSound {
  /// Preserves the incoming APNs sound, or adds the default when no sound exists.
  public static func preparing(
    _ content: UNNotificationContent,
    originalSound: UNNotificationSound?
  ) -> UNNotificationContent {
    // UNNotificationContent's NSMutableCopying contract returns its mutable counterpart.
    let prepared = content.mutableCopy() as! UNMutableNotificationContent
    prepared.sound = originalSound ?? content.sound ?? .default
    return prepared
  }
}
