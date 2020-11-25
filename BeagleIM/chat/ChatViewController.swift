//
// ChatViewController.swift
//
// BeagleIM
// Copyright (C) 2018 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import AppKit
import TigaseSwift
import TigaseSwiftOMEMO

class ChatViewController: AbstractChatViewControllerWithSharing, ConversationLogContextMenuDelegate, NSMenuItemValidation {

    @IBOutlet var buddyAvatarView: AvatarViewWithStatus!
    @IBOutlet var buddyNameLabel: NSTextFieldCell!
    @IBOutlet var buddyJidLabel: NSTextFieldCell!
    @IBOutlet var buddyStatusLabel: NSTextField!;

    fileprivate var lastTextChange: Date = Date();
    fileprivate var lastTextChangeTimer: Foundation.Timer?;

    @IBOutlet var audioCall: NSButton!
    @IBOutlet var videoCall: NSButton!
    @IBOutlet var infoButton: NSButton!;

    @IBOutlet var scriptsButton: NSPopUpButton!;

    @IBOutlet var encryptButton: NSPopUpButton!;
    
    override func viewDidLoad() {
        super.viewDidLoad();

        audioCall.isHidden = true;
        videoCall.isHidden = true;
        scriptsButton.isHidden = true;

        let cgRef = infoButton.image!.cgImage(forProposedRect: nil, context: nil, hints: nil);
        let representation = NSBitmapImageRep(cgImage: cgRef!);
        let newRep = representation.converting(to: .genericGray, renderingIntent: .default);
        infoButton.image = NSImage(cgImage: newRep!.cgImage!, size: infoButton.frame.size);

        NotificationCenter.default.addObserver(self, selector: #selector(rosterItemUpdated), name: DBRosterStore.ITEM_UPDATED, object: nil);
        NotificationCenter.default.addObserver(self, selector: #selector(avatarChanged), name: AvatarManager.AVATAR_CHANGED, object: nil);
        NotificationCenter.default.addObserver(self, selector: #selector(contactPresenceChanged), name: XmppService.CONTACT_PRESENCE_CHANGED, object: nil);
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.CHANGED, object: nil);
        NotificationCenter.default.addObserver(self, selector: #selector(omemoAvailabilityChanged), name: MessageEventHandler.OMEMO_AVAILABILITY_CHANGED, object: nil);
    }

    override func viewWillAppear() {
        self.conversationLogController?.contextMenuDelegate = self;

        buddyNameLabel.title = chat.displayName;
        buddyJidLabel.title = jid.stringValue;
        buddyAvatarView.backgroundColor = NSColor(named: "chatBackgroundColor")!;
        buddyAvatarView.name = chat.displayName;
        buddyAvatarView.update(for: jid, on: account);
        let presenceModule: PresenceModule? = XmppService.instance.getClient(for: account)?.modulesManager.getModule(PresenceModule.ID);
        let status = presenceModule?.store.getBestPresence(for: jid)?.status;
        buddyStatusLabel.stringValue = status ?? "";
        buddyStatusLabel.toolTip = status;

        let itemsCount = self.scriptsButton.menu?.items.count ?? 0;
        if itemsCount > 1 {
            for _ in 1..<itemsCount {
                self.scriptsButton.menu?.removeItem(at: 1)
            }
        }
        if let scripts = ScriptsManager.instance.contactScripts() {
            scripts.forEach { (script) in
                let item = NSMenuItem(title: script.name, action: #selector(scriptActivated(sender:)), keyEquivalent: "");
                item.target = self;
                self.scriptsButton.menu?.addItem(item);
            }
        }
        self.scriptsButton.isHidden = ScriptsManager.instance.contactScripts() == nil;

        self.updateCapabilities();

        super.viewWillAppear();
        lastTextChangeTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { (timer) in
            if self.lastTextChange.timeIntervalSinceNow < -10.0 {
                self.change(chatState: .active);
            }
        });

        refreshEncryptionStatus();
    }
    
    @objc func omemoAvailabilityChanged(_ notification: Notification) {
        guard let event = notification.object as? OMEMOModule.AvailabilityChangedEvent else {
            return;
        }
        guard event.account == self.account && self.jid == event.jid else {
            return;
        }
        refreshEncryptionStatus();
    }

    @objc func scriptActivated(sender: NSMenuItem) {
        ScriptsManager.instance.contactScripts()?.first(where: { (item) -> Bool in
            return item.name == sender.title;
        })?.execute(account: self.account, jid: JID(self.jid));
    }

    override func viewWillDisappear() {
        super.viewWillDisappear();
        lastTextChangeTimer?.invalidate();
        lastTextChangeTimer = nil;
        change(chatState: .active);
    }

    fileprivate func change(chatState: ChatState) {
        guard let message = (self.chat as? Chat)?.changeChatState(state: chatState) else {
            return;
        }
        guard let messageModule: MessageModule = XmppService.instance.getClient(for: account)?.modulesManager.getModule(MessageModule.ID) else {
            return;
        }
        messageModule.write(message);
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification);
        lastTextChange = Date();
        self.change(chatState: .composing);
    }
    

    @objc func rosterItemUpdated(_ notification: Notification) {
        guard let e = notification.object as? RosterModule.ItemUpdatedEvent else {
            return;
        }

        guard let account = e.sessionObject.userBareJid, let item = e.rosterItem else {
            return;
        }

        DispatchQueue.main.async { [weak self] in
            guard let that = self, that.account == account && that.jid == item.jid.bareJid else {
                return;
            }

            let buddyName = that.chat.displayName;
            that.buddyNameLabel.title = buddyName;
            that.buddyAvatarView.name = buddyName;
            that.dataSource.refreshDataNoReload();
        }
    }

    @objc func avatarChanged(_ notification: Notification) {
        guard let account = notification.userInfo?["account"] as? BareJID, let jid = notification.userInfo?["jid"] as? BareJID else {
            return;
        }
        guard self.account == account && (self.jid == jid || self.account == jid) else {
            return;
        }
        DispatchQueue.main.async {
            self.buddyAvatarView.avatar = AvatarManager.instance.avatar(for: jid, on: account);
            self.conversationLogController?.tableView.reloadData();
        }
    }

    @objc func contactPresenceChanged(_ notification: Notification) {
        guard let e = notification.object as? PresenceModule.ContactPresenceChanged else {
            return;
        }

        guard let account = e.sessionObject.userBareJid, let jid = e.presence.from?.bareJid else {
            return;
        }

        guard account == self.account && jid == self.jid else {
            return;
        }

        DispatchQueue.main.async {
            self.buddyAvatarView.update(for: jid, on: account);
            let status = e.presence.status;
            self.buddyStatusLabel.stringValue = status ?? "";
            self.buddyStatusLabel.toolTip = status;
        }

        self.updateCapabilities();
    }

    override func prepareConversationLogContextMenu(dataSource: ConversationDataSource, menu: NSMenu, forRow row: Int) {
        super.prepareConversationLogContextMenu(dataSource: dataSource, menu: menu, forRow: row);
        if let item = dataSource.getItem(at: row) as? ConversationEntryWithSender, item.state.direction == .outgoing && (item is ConversationMessage || item is ConversationAttachment) {
            if item.state.isError {
                let resend = menu.addItem(withTitle: "Resend message", action: #selector(resendMessage), keyEquivalent: "");
                resend.target = self;
                resend.tag = item.id;
            } else {
                if item is ConversationMessage && !dataSource.isAnyMatching({ ($0 as? ConversationEntryWithSender)?.state.direction == .outgoing && $0 is ConversationMessage }, in: 0..<row) {
                    let correct = menu.addItem(withTitle: "Correct message", action: #selector(correctMessage), keyEquivalent: "");
                    correct.target = self;
                    correct.tag = item.id;
                }
                
                if XmppService.instance.getClient(for: item.conversation.account)?.state ?? .disconnected == .connected {
                    let retract = menu.addItem(withTitle: "Retract message", action: #selector(retractMessage), keyEquivalent: "");
                    retract.target = self;
                    retract.tag = item.id;
                }
            }
        }
    }

    @objc func resendMessage(_ sender: NSMenuItem) {
        let tag = sender.tag;
        guard tag >= 0 else {
            return;
        }

        guard let item = dataSource.getItem(withId: tag), let chat = self.chat as? Chat else {
            return;
        }

        switch item {
        case let item as ConversationMessage:
            chat.sendMessage(text: item.message, correctedMessageOriginId: nil);
            DBChatHistoryStore.instance.remove(item: item);
        case let item as ConversationAttachment:
            let oldLocalFile = DownloadStore.instance.url(for: "\(item.id)");
            chat.sendAttachment(url: item.url, appendix: item.appendix, originalUrl: oldLocalFile, completionHandler: {
                DBChatHistoryStore.instance.remove(item: item);
            })
        default:
            break;
        }
    }
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(correctLastMessage(_:)):
            return messageField.string.isEmpty;
        default:
            return true;
        }
    }
    
    @IBAction func correctLastMessage(_ sender: AnyObject) {
        for i in 0..<dataSource.count {
            if let item = dataSource.getItem(at: i) as? ConversationMessage, item.state.direction == .outgoing {
                DBChatHistoryStore.instance.originId(for: item.account, with: item.conversation.jid, id: item.id, completionHandler: { [weak self] originId in
                    self?.startMessageCorrection(message: item.message, originId: originId);
                })
                return;
            }
        }
    }
    
    @objc func correctMessage(_ sender: NSMenuItem) {
        let tag = sender.tag;
        guard tag >= 0 else {
            return
        }
     
        guard let item = dataSource.getItem(withId: tag) as? ConversationMessage else {
            return;
        }
        
        DBChatHistoryStore.instance.originId(for: item.account, with: item.conversation.jid, id: item.id, completionHandler: { [weak self] originId in
            self?.startMessageCorrection(message: item.message, originId: originId);
        })
    }

    @objc func retractMessage(_ sender: NSMenuItem) {
        let tag = sender.tag;
        guard tag >= 0 else {
            return
        }
        
        guard let item = dataSource.getItem(withId: tag) as? ConversationEntryWithSender, let chat = self.chat as? Chat else {
            return;
        }
        
        let alert = NSAlert();
        alert.messageText = "Are you sure you want to retract that message?"
        alert.informativeText = "That message will be removed immediately and it's receives will be asked to remove it as well.";
        alert.addButton(withTitle: "Retract");
        alert.addButton(withTitle: "Cancel");
        alert.beginSheetModal(for: self.view.window!, completionHandler: { result in
            switch result {
            case .alertFirstButtonReturn:
                chat.retract(entry: item);
            default:
                break;
            }
        })
    }
        
    override func send(message: String, correctedMessageOriginId: String?) -> Bool {
        guard let chat = self.chat as? Chat else {
            return false;
            
        }
        chat.sendMessage(text: message, correctedMessageOriginId: correctedMessageOriginId);
        return true;
    }
            
    fileprivate func updateCapabilities() {
        let supported = JingleManager.instance.support(for: JID(jid), on: account);
        DispatchQueue.main.async {
            self.audioCall.isHidden = !(VideoCallController.hasAudioSupport && (supported.contains(.audio) || Settings.ignoreJingleSupportCheck.bool()));
            self.videoCall.isHidden = !(VideoCallController.hasAudioSupport && VideoCallController.hasVideoSupport && (supported.contains(.video) || Settings.ignoreJingleSupportCheck.bool()));
        }
    }

    @IBAction func audioCallClicked(_ sender: Any) {
        let call = Call(account: self.account, with: self.jid, sid: UUID().uuidString, direction: .outgoing, media: [.audio]);
        CallManager.instance.reportOutgoingCall(call, completionHandler: self.handleCallInitiationResult(_:));
    }

    @IBAction func videoCallClicked(_ sender: NSButton) {
        let call = Call(account: self.account, with: self.jid, sid: UUID().uuidString, direction: .outgoing, media: [.audio, .video]);
        CallManager.instance.reportOutgoingCall(call, completionHandler: self.handleCallInitiationResult(_:));
    }
    
    func handleCallInitiationResult(_ result: Result<Void,Error>) {
        switch result {
        case .success(_):
            break;
        case .failure(let err):
            let alert = NSAlert();
            alert.alertStyle = .warning;
            alert.messageText = "Call failed";
            alert.informativeText = "It was not possible to establish call";
            switch err {
            case let e as ErrorCondition:
                switch e {
                case .forbidden:
                    alert.informativeText = "It was not possible to access camera or microphone. Please check permissions in the system settings";
                default:
                    break;
                }
            default:
                break;
            }
            guard let window = self.view.window else {
                return;
            }
            alert.addButton(withTitle: "OK");
            alert.beginSheetModal(for: window, completionHandler: nil);
        }
    }

    @IBAction func encryptionChanged(_ sender: NSPopUpButton) {
        var encryption: ChatEncryption? = nil;
        switch sender.indexOfSelectedItem {
        case 2:
            encryption = ChatEncryption.none;
        case 3:
            encryption = ChatEncryption.omemo;
        default:
            encryption = nil;
        }

        guard let chat = self.chat as? Chat else {
            return;
        }
        chat.modifyOptions({ (options) in
            options.encryption = encryption;
        }, completionHandler: {
            DispatchQueue.main.async {
                self.refreshEncryptionStatus();
            }
        })
    }

    @objc func settingsChanged(_ notification: Notification) {
        guard let setting = notification.object as? Settings else {
            return;
        }

        if setting == Settings.messageEncryption {
            refreshEncryptionStatus();
        }
    }

    fileprivate func refreshEncryptionStatus() {
        DispatchQueue.main.async {
            guard let account = self.account, let jid = self.jid else {
                return;
            }
            let omemoModule: OMEMOModule? = XmppService.instance.getClient(for: account)?.modulesManager.getModule(OMEMOModule.ID);
            self.encryptButton.isEnabled = omemoModule?.isAvailable(for: jid) ?? false//!DBOMEMOStore.instance.allDevices(forAccount: account!, andName: jid!.stringValue, activeAndTrusted: false).isEmpty;
            if !self.encryptButton.isEnabled {
                self.encryptButton.item(at: 0)?.image = NSImage(named: NSImage.lockUnlockedTemplateName);
            } else {
                let encryption = (self.chat as? Chat)?.options.encryption ?? ChatEncryption(rawValue: Settings.messageEncryption.string()!)!;
                let locked = encryption == ChatEncryption.omemo;
                self.encryptButton.item(at: 0)?.image = locked ? NSImage(named: NSImage.lockLockedTemplateName) : NSImage(named: NSImage.lockUnlockedTemplateName);
            }
        }
    }

    @IBAction func showInfoClicked(_ sender: NSButton) {
        let storyboard = NSStoryboard(name: "ConversationDetails", bundle: nil);
        guard let viewController = storyboard.instantiateController(withIdentifier: "ContactDetailsViewController") as? ContactDetailsViewController else {
            return;
        }
        viewController.account = self.account;
        viewController.jid = self.jid;
        viewController.viewType = .chat;

        let popover = NSPopover();
        popover.contentViewController = viewController;
        popover.behavior = .semitransient;
        popover.animates = true;
        let rect = sender.convert(sender.bounds, to: self.view.window!.contentView!);
        popover.show(relativeTo: rect, of: self.view.window!.contentView!, preferredEdge: .minY);
    }
}

enum MessageSendError: Error {
    case internalError
    case unknownError(String)

    var stanzaId: String? {
        switch self {
        case .unknownError(let stanzaId):
            return stanzaId;
        default:
            return nil;
        }
    }
}

public enum PreviewError: String, Error {
    case NoData = "no_data";
    case Error = "error";
}

public enum MessageState: Int {

    // x % 2 == 0 - incoming
    // x % 2 == 1 - outgoing
    case incoming = 0
    case outgoing = 1

    case incoming_unread = 2
    case outgoing_unsent = 3

    case incoming_error = 4
    case outgoing_error = 5

    case incoming_error_unread = 6
    case outgoing_error_unread = 7

    case outgoing_delivered = 9
    case outgoing_read = 11
    
//    case incoming_retracted = 12
//    case outgoing_retracted = 13

    var direction: MessageDirection {
        switch self {
        case .incoming, .incoming_unread, .incoming_error, .incoming_error_unread://, .incoming_retracted:
            return .incoming;
        case .outgoing, .outgoing_unsent, .outgoing_delivered, .outgoing_read, .outgoing_error_unread, .outgoing_error://, .outgoing_retracted:
            return .outgoing;
        }
    }

    var isError: Bool {
        switch self {
        case .incoming_error, .incoming_error_unread, .outgoing_error, .outgoing_error_unread:
            return true;
        default:
            return false;
        }
    }

    var isUnread: Bool {
        switch self {
        case .incoming_unread, .incoming_error_unread, .outgoing_error_unread:
            return true;
        default:
            return false;
        }
    }

}

public enum MessageDirection: Int {
    case incoming = 0
    case outgoing = 1
}

class ChatViewTableView: NSTableView {

    static let didScrollRowToVisible = Notification.Name("ChatViewTableView::didScrollRowToVisible");

    override var acceptsFirstResponder: Bool {
        return true;
    }
    
    weak var mouseDelegate: ChatViewTableViewMouseDelegate?;
    
    override open var isFlipped: Bool {
        return false;
    }
    
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView);
        print("reflectScrolledClipView called!");
    }
    override func scrollRowToVisible(_ row: Int) {
        let numberOfRows = self.dataSource?.numberOfRows?(in: self) ?? 0;
        guard numberOfRows > row else {
            print("cannot scroll to row", row, "as data source has only", numberOfRows, "rows");
            return;
        }

//        guard row == 0 else {
//            let rect = self.rect(ofRow: row);
//            self.scrollToVisible(NSRect(origin: NSPoint(x: rect.origin.x, y: (rect.origin.y - max(0, self.visibleRect.height - rect.size.height))), size: rect.size));
//            return;
//        }

        super.scrollRowToVisible(row);
        let visibleRows = self.rows(in: self.visibleRect);
        if !visibleRows.contains(row) {
            print("visible rows:", visibleRows, "need:", row);
            DispatchQueue.main.async {
                self.scrollRowToVisible(row);
            }
        } else {
            print("scrollRowToVisible called!");
            NotificationCenter.default.post(name: ChatViewTableView.didScrollRowToVisible, object: self);
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        if !(mouseDelegate?.handleMouse(event: event) ?? false) {
            super.mouseDown(with: event);
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        if !(mouseDelegate?.handleMouse(event: event) ?? false) {
            super.mouseUp(with: event);
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        if !(mouseDelegate?.handleMouse(event: event) ?? false) {
            super.mouseDragged(with: event);
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        if !(mouseDelegate?.handleMouse(event: event) ?? false) {
            super.rightMouseDown(with: event);
        }
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextView {
            return false;
        } else {
            return super.validateProposedFirstResponder(responder, for: event);
        }
    }
    
}

protocol ChatViewTableViewMouseDelegate: class {
    func handleMouse(event: NSEvent) -> Bool;
}

class ChatViewStatusView: NSTextField {

}
