import SwiftUI
import AppKit
import Combine
import UserNotifications

@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var inputText: String = ""
    @Published var currentConversation: Conversation?
    @Published var messages: [Message] = []
    @Published var isLoading: Bool = false
    @Published var agentStatusText: String?
    @Published var pendingAttachments: [PendingAttachment] = []
    @Published var recentConversations: [Conversation] = []

    // Track pending message per conversation for cancel/restore
    private struct PendingMessage {
        let text: String
        let messageId: UUID
        let attachments: [PendingAttachment]
    }
    private var pendingMessages: [UUID: PendingMessage] = [:]  // keyed by conversation ID

    // Track which conversations have in-progress requests (for background loading)
    private var loadingConversationIds: Set<UUID> = []

    // MARK: - Dependencies

    private let database = Database.shared
    private var agentLoops: [UUID: AgentLoop] = [:]  // One loop per conversation
    private let attachmentManager = AttachmentManager.shared
    private var agentStateSubscription: AnyCancellable?

    /// Get or create an AgentLoop for a conversation
    private func agentLoop(for conversationId: UUID) -> AgentLoop {
        if let existing = agentLoops[conversationId] {
            return existing
        }
        let newLoop = AgentLoop()
        agentLoops[conversationId] = newLoop
        return newLoop
    }

    // MARK: - Computed Properties

    var canAddAttachment: Bool {
        pendingAttachments.count < AttachmentConstants.maxAttachmentsPerMessage
    }

    // MARK: - Initialization

    init() {
        // Start blank - session restoration is handled by SpotlightPanelController
        recentConversations = database.getAllConversations()
    }

    // MARK: - Conversation Management

    func startNewConversation() {
        currentConversation = nil
        messages = []
        inputText = ""
        pendingAttachments = []
        isLoading = false
    }

    func loadConversation(_ conversation: Conversation) {
        currentConversation = conversation
        messages = database.getMessages(conversationId: conversation.id).filter(\.isDisplayMessage)
        // Clear draft when navigating via menu (not session restore)
        inputText = ""
        pendingAttachments = []
        // Restore loading state if this conversation has an in-progress request
        isLoading = loadingConversationIds.contains(conversation.id)
        subscribeToAgentState(for: conversation.id)
        // Dismiss any pending notification for this conversation
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["response-\(conversation.id.uuidString)"]
        )
    }

    // MARK: - Attachment Management

    func addAttachment(_ pending: PendingAttachment) {
        guard canAddAttachment else { return }
        pendingAttachments.append(pending)
    }

    func addAttachments(_ newAttachments: [PendingAttachment]) {
        let remaining = AttachmentConstants.maxAttachmentsPerMessage - pendingAttachments.count
        let toAdd = Array(newAttachments.prefix(remaining))
        pendingAttachments.append(contentsOf: toAdd)

    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func handlePaste(from pasteboard: NSPasteboard) {
        let newAttachments = attachmentManager.loadFromPasteboard(pasteboard)
        if !newAttachments.isEmpty {
            addAttachments(newAttachments)
        }
    }

    // MARK: - Message Handling

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Allow sending with just attachments (no text required if there are images)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isLoading else { return }

        // Store attachments before clearing
        let messageAttachments = pendingAttachments
        inputText = ""
        pendingAttachments = []
        isLoading = true

        // Create conversation in memory if needed (not persisted yet)
        if currentConversation == nil {
            currentConversation = Conversation()
        }

        guard let conversation = currentConversation else { return }

        // Track that this conversation has an in-progress request
        loadingConversationIds.insert(conversation.id)

        // Save attachments to disk and get Attachment objects
        var savedAttachments: [Attachment] = []
        for pending in messageAttachments {
            if let saved = attachmentManager.save(pending: pending, conversationId: conversation.id) {
                savedAttachments.append(saved)
            }
        }

        // Create user message with dynamic context (date/time/location) baked in for prompt caching
        let userMessage = Message.userMessage(
            conversationId: conversation.id,
            content: text,
            attachments: savedAttachments.isEmpty ? nil : savedAttachments
        )
        messages.append(userMessage)

        // Store for potential cancel/restore (keyed by conversation ID)
        pendingMessages[conversation.id] = PendingMessage(
            text: text,
            messageId: userMessage.id,
            attachments: messageAttachments
        )

        // Save conversation and user message immediately so they persist if popup is closed
        if database.getConversation(id: conversation.id) == nil {
            database.createConversation(conversation)
            refreshRecentConversations()
        }
        database.createMessage(userMessage)

        // Subscribe to agent state for live status text
        let loop = agentLoop(for: conversation.id)
        agentStateSubscription = loop.$state
            .sink { [weak self] state in
                guard let self = self,
                      self.currentConversation?.id == conversation.id else { return }
                self.agentStatusText = self.statusText(for: state)
            }

        // Load ALL messages (including intermediates) for API context, not just UI-visible ones.
        // The conversation and user message were already saved above, so getMessages includes everything.
        var allMessages = database.getMessages(conversationId: conversation.id)

        // Clean up orphaned messages from a previous interrupted turn (e.g., app crash
        // during tool loop). Remove any intermediate tool messages, then remove any
        // unanswered user message to ensure proper role alternation.
        while allMessages.count >= 2 {
            let beforeNew = allMessages[allMessages.count - 2]
            guard beforeNew.toolCalls != nil && !beforeNew.toolCalls!.isEmpty else { break }
            database.deleteMessage(id: beforeNew.id)
            allMessages.remove(at: allMessages.count - 2)
        }
        if allMessages.count >= 2 && allMessages[allMessages.count - 2].role == .user {
            database.deleteMessage(id: allMessages[allMessages.count - 2].id)
            allMessages.remove(at: allMessages.count - 2)
        }

        // Run agent (use per-conversation loop for concurrent requests)
        loop.run(
            messages: allMessages,
            onIntermediateMessage: { [weak self] message in
                // Persist intermediate tool_use/tool_result messages to DB for future context
                self?.database.createMessage(message)
            }
        ) { [weak self] responseText, toolCalls in
            guard let self = self else { return }

            let toolUsageSummary = Message.generateToolUsageSummary(from: toolCalls)

            // Save the final assistant message (no tool calls — this is the display message)
            let assistantMessage = Message(
                conversationId: conversation.id,
                role: .assistant,
                content: responseText,
                toolUsageSummary: toolUsageSummary
            )
            self.database.createMessage(assistantMessage)

            // Update conversation timestamp in database (always)
            var updatedConversation = conversation
            updatedConversation.updatedAt = Date()
            self.database.updateConversation(updatedConversation)
            self.refreshRecentConversations()

            // Request completed - remove from tracking sets
            self.loadingConversationIds.remove(conversation.id)
            self.pendingMessages.removeValue(forKey: conversation.id)

            // Check if we're still viewing the same conversation
            let isStillCurrentConversation = self.currentConversation?.id == conversation.id

            // Only update UI state if still in the same conversation
            if isStillCurrentConversation {
                self.messages.append(assistantMessage)
                self.currentConversation = updatedConversation
                self.isLoading = false
            }

            // Update title after each exchange (DB always, UI only if still current)
            Task {
                if let title = await self.agentLoop(for: conversation.id).generateTitle(for: self.database.getMessages(conversationId: conversation.id).filter(\.isDisplayMessage)) {
                    // Read fresh from DB to avoid overwriting newer timestamps from subsequent messages
                    if var conv = self.database.getConversation(id: conversation.id) {
                        conv.title = title
                        self.database.updateConversation(conv)
                        self.refreshRecentConversations()
                        if self.currentConversation?.id == conversation.id {
                            self.currentConversation = conv
                        }
                    }
                }
            }

            // Notify user if this conversation is not visible (panel hidden or different conversation open)
            let conversationNotVisible = !SpotlightPanelController.shared.isVisible || !isStillCurrentConversation
            if conversationNotVisible {
                // Clean up markdown for notification preview
                let cleanSummary = responseText
                    .replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                NotificationManager.shared.notifyResponseReady(summary: cleanSummary, conversationId: conversation.id)
            }
        }
    }

    func cancelRequest() {
        guard let conversation = currentConversation else { return }

        agentLoop(for: conversation.id).cancel()
        isLoading = false
        loadingConversationIds.remove(conversation.id)

        // Get pending message for THIS conversation
        guard let pending = pendingMessages[conversation.id] else { return }

        // Restore the user's message text
        inputText = pending.text

        // Restore attachments - but we need to recreate PendingAttachments
        // from the saved files if they were already saved
        if let message = messages.first(where: { $0.id == pending.messageId }),
           let attachments = message.attachments {
            // Reload as pending attachments for editing
            pendingAttachments = attachments.compactMap { attachment in
                guard let data = attachment.loadImageData(),
                      let image = NSImage(data: data) else { return nil }
                return PendingAttachment(id: attachment.id, image: image, filename: attachment.filename)
            }

            // Delete the saved files since we're canceling
            for attachment in attachments {
                attachmentManager.delete(attachment: attachment)
            }
        } else {
            // Restore from in-memory pending attachments
            pendingAttachments = pending.attachments
        }

        // Remove the pending user message and any intermediate tool messages from this turn.
        // Intermediate messages (tool_use/tool_result) are persisted during the agent loop,
        // so we need to clean them up on cancel to avoid orphaned messages.
        if let userMessage = messages.first(where: { $0.id == pending.messageId }) {
            database.deleteMessages(conversationId: conversation.id, after: userMessage.createdAt)
        }
        messages.removeAll { $0.id == pending.messageId }
        database.deleteMessage(id: pending.messageId)

        // Clear pending message for this conversation
        pendingMessages.removeValue(forKey: conversation.id)

        // If this was a new conversation with no completed messages, delete it
        if messages.isEmpty {
            agentLoops.removeValue(forKey: conversation.id)
            database.deleteConversation(id: conversation.id)
            refreshRecentConversations()
            currentConversation = nil
        }
    }

    // MARK: - Conversations

    private func refreshRecentConversations() {
        recentConversations = database.getAllConversations()
    }

    func searchConversations(query: String) -> [Conversation] {
        if query.isEmpty {
            return database.getAllConversations()
        }
        return database.searchConversations(query: query)
    }

    func deleteConversation(_ conversation: Conversation) {
        // Cancel any in-progress request and clean up
        agentLoops[conversation.id]?.cancel()
        agentLoops.removeValue(forKey: conversation.id)
        loadingConversationIds.remove(conversation.id)
        pendingMessages.removeValue(forKey: conversation.id)

        // Delete attachment files too
        attachmentManager.deleteAll(for: conversation.id)

        database.deleteConversation(id: conversation.id)
        refreshRecentConversations()
        if currentConversation?.id == conversation.id {
            startNewConversation()
        }
    }

    // MARK: - Agent Status

    /// Re-subscribe to agent state for a conversation (used when switching back to a loading conversation)
    private func subscribeToAgentState(for conversationId: UUID) {
        agentStateSubscription?.cancel()
        guard loadingConversationIds.contains(conversationId),
              let loop = agentLoops[conversationId] else {
            agentStatusText = nil
            return
        }
        agentStatusText = statusText(for: loop.state)
        agentStateSubscription = loop.$state
            .sink { [weak self] state in
                guard let self = self,
                      self.currentConversation?.id == conversationId else { return }
                self.agentStatusText = self.statusText(for: state)
            }
    }

    private func statusText(for state: AgentState) -> String? {
        switch state {
        case .thinking:
            return "Thinking..."
        case .executingTool(let toolName):
            switch toolName {
            case "web_search":
                return "Searching the web..."
            case "get_page_contents":
                return "Reading the web..."
            case "reddit_search":
                return "Searching Reddit..."
            case "reddit_read":
                return "Reading Reddit..."
            default:
                return "Working..."
            }
        default:
            return nil
        }
    }
}
