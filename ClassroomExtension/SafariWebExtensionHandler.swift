import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let reply = NSExtensionItem()
        do {
            guard let message = (context.inputItems.first as? NSExtensionItem)?
                .userInfo?[SFExtensionMessageKey], JSONSerialization.isValidJSONObject(message) else {
                throw CocoaError(.coderInvalidValue)
            }
            let data = try JSONSerialization.data(withJSONObject: message)
            let snapshot = try JSONDecoder().decode(ClassroomWebSnapshot.self, from: data)
            guard snapshot.isValid else { throw CocoaError(.coderInvalidValue) }

            let destination = try ClassroomWebSnapshot.inbox().appendingPathComponent("pending.json")
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            reply.userInfo = [SFExtensionMessageKey: ["ok": true]]
        } catch {
            reply.userInfo = [SFExtensionMessageKey: ["ok": false, "error": "Unable to stage the import. Check extension signing and the shared App Group."]]
        }
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }
}
