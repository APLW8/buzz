import Testing
import UserNotifications

@testable import BuzzPushKit

struct BuzzNotificationSoundTests {
  @Test func `Missing sound receives default without changing presentation`() {
    let content = UNMutableNotificationContent()
    content.title = "Sender"
    content.body = "Message"
    content.userInfo = ["navigation": "target"]
    let result = BuzzNotificationSound.preparing(content, originalSound: nil)
    #expect(result.sound != nil)
    #expect(content.sound == nil)
    #expect(result.title == content.title)
    #expect(result.body == content.body)
    #expect(result.userInfo["navigation"] as? String == "target")
  }

  @Test func `Gateway sound survives enrichment that omits or replaces it`() {
    let gatewaySound = UNNotificationSound(named: UNNotificationSoundName("gateway.caf"))
    for enrichedSound in [nil, UNNotificationSound.default] {
      let enriched = UNMutableNotificationContent()
      enriched.sound = enrichedSound
      let result = BuzzNotificationSound.preparing(enriched, originalSound: gatewaySound)
      #expect(result.sound?.isEqual(gatewaySound) == true)
    }
  }

  @Test func `Existing enriched sound survives when gateway supplied none`() {
    let enriched = UNMutableNotificationContent()
    let custom = UNNotificationSound(named: UNNotificationSoundName("enriched.caf"))
    enriched.sound = custom
    let result = BuzzNotificationSound.preparing(enriched, originalSound: nil)
    #expect(result.sound?.isEqual(custom) == true)
  }

  @Test(arguments: [true, false])
  func `Final handoff applies sound to resolved and restricted content once`(allowed: Bool) {
    var delivered: [UNNotificationContent] = []
    let original = UNMutableNotificationContent()
    let handoff = BuzzNotificationHandoff<UNNotificationContent> { content in
      delivered.append(BuzzNotificationSound.preparing(content, originalSound: original.sound))
    }
    let resolved = UNMutableNotificationContent()
    resolved.title = "Sender"
    let fallback = UNMutableNotificationContent()
    fallback.title = "Buzz"
    for _ in 0..<2 {
      handoff.finish(
        resolved,
        restrictedFallback: fallback,
        handoffIfAllowed: { deliver in
          if allowed { deliver() }
          return allowed
        },
        cleanup: { #expect(delivered.first?.sound != nil) }
      )
    }
    #expect(delivered.count == 1)
    #expect(delivered.first?.title == (allowed ? "Sender" : "Buzz"))
    #expect(delivered.first?.sound != nil)
  }

  @Test func `Expiration receives sound before a late resolution is ignored`() {
    var delivered: [UNNotificationContent] = []
    let handoff = BuzzNotificationHandoff<UNNotificationContent> { content in
      delivered.append(BuzzNotificationSound.preparing(content, originalSound: nil))
    }
    for body in ["Reconnect to your relay now", "Resolved message"] {
      let content = UNMutableNotificationContent()
      content.body = body
      handoff.finish(
        content, restrictedFallback: content,
        handoffIfAllowed: { deliver in deliver(); return true }, cleanup: {}
      )
    }
    #expect(delivered.count == 1)
    #expect(delivered.first?.body == "Reconnect to your relay now")
    #expect(delivered.first?.sound != nil)
  }
}

#if os(iOS)
  import Intents

  extension BuzzNotificationSoundTests {
    @Test func `Real communication intent update retains the original sound at handoff`() throws {
      let descriptor = BuzzCommunicationNotificationDescriptor(
        senderDisplayName: "Alice", senderIdentifier: "sender",
        senderAvatarPNG: nil, messageBody: "Hello", conversationIdentifier: "conversation",
        conversationDisplayName: "General", recipientCount: 1
      )
      let intent = BuzzCommunicationNotificationPresenter.makeIntent(descriptor)
      for incomingSound in [nil, UNNotificationSound(named: UNNotificationSoundName("gateway.caf"))] {
        let original = UNMutableNotificationContent()
        original.sound = incomingSound
        let specialized = try original.updating(from: intent)
        let result = BuzzNotificationSound.preparing(specialized, originalSound: original.sound)
        if let incomingSound {
          #expect(result.sound?.isEqual(incomingSound) == true)
        } else {
          #expect(result.sound != nil)
        }
        #expect(result.title == specialized.title)
        #expect(result.body == specialized.body)
      }
    }
  }
#endif
