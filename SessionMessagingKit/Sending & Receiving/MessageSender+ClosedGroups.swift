import PromiseKit

extension MessageSender {
    public static var distributingClosedGroupEncryptionKeyPairs: [String:[ECKeyPair]] = [:]
    
    public static func createClosedGroup(name: String, members: Set<String>, transaction: YapDatabaseReadWriteTransaction) -> Promise<TSGroupThread> {
        // Prepare
        var members = members
        let userPublicKey = getUserHexEncodedPublicKey()
        // Generate the group's public key
        let groupPublicKey = Curve25519.generateKeyPair().hexEncodedPublicKey // Includes the "05" prefix
        // Generate the key pair that'll be used for encryption and decryption
        let encryptionKeyPair = Curve25519.generateKeyPair()
        // Ensure the current user is included in the member list
        members.insert(userPublicKey)
        let membersAsData = members.map { Data(hex: $0) }
        // Create the group
        let admins = [ userPublicKey ]
        let adminsAsData = admins.map { Data(hex: $0) }
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let group = TSGroupModel(title: name, memberIds: [String](members), image: nil, groupId: groupID, groupType: .closedGroup, adminIds: admins)
        let thread = TSGroupThread.getOrCreateThread(with: group, transaction: transaction)
        thread.save(with: transaction)
        // Send a closed group update message to all members individually
        var promises: [Promise<Void>] = []
        for member in members {
            let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
            thread.save(with: transaction)
            let closedGroupControlMessageKind = ClosedGroupControlMessage.Kind.new(publicKey: Data(hex: groupPublicKey), name: name,
                encryptionKeyPair: encryptionKeyPair, members: membersAsData, admins: adminsAsData)
            let closedGroupControlMessage = ClosedGroupControlMessage(kind: closedGroupControlMessageKind)
            let promise = MessageSender.sendNonDurably(closedGroupControlMessage, in: thread, using: transaction)
            promises.append(promise)
        }
        // Add the group to the user's set of public keys to poll for
        Storage.shared.addClosedGroupPublicKey(groupPublicKey, using: transaction)
        // Store the key pair
        Storage.shared.addClosedGroupEncryptionKeyPair(encryptionKeyPair, for: groupPublicKey, using: transaction)
        // Notify the PN server
        promises.append(PushNotificationAPI.performOperation(.subscribe, for: groupPublicKey, publicKey: userPublicKey))
        // Notify the user
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .groupUpdate)
        infoMessage.save(with: transaction)
        // Return
        return when(fulfilled: promises).map2 { thread }
    }

    public static func generateAndSendNewEncryptionKeyPair(for groupPublicKey: String, to targetMembers: Set<String>, using transaction: Any) throws {
        // Prepare
        let transaction = transaction as! YapDatabaseReadWriteTransaction
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let threadID = TSGroupThread.threadId(fromGroupId: groupID)
        guard let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
            SNLog("Can't distribute new encryption key pair for nonexistent closed group.")
            throw Error.noThread
        }
        guard thread.groupModel.groupAdminIds.contains(getUserHexEncodedPublicKey()) else {
            SNLog("Can't distribute new encryption key pair as a non-admin.")
            throw Error.invalidClosedGroupUpdate
        }
        // Generate the new encryption key pair
        let newKeyPair = Curve25519.generateKeyPair()
        // Distribute it
        let proto = try SNProtoKeyPair.builder(publicKey: newKeyPair.publicKey,
            privateKey: newKeyPair.privateKey).build()
        let plaintext = try proto.serializedData()
        let wrappers = try targetMembers.compactMap { publicKey -> ClosedGroupControlMessage.KeyPairWrapper in
            let ciphertext = try MessageSender.encryptWithSessionProtocol(plaintext, for: publicKey)
            return ClosedGroupControlMessage.KeyPairWrapper(publicKey: publicKey, encryptedKeyPair: ciphertext)
        }
        let closedGroupControlMessage = ClosedGroupControlMessage(kind: .encryptionKeyPair(publicKey: nil, wrappers: wrappers))
        var distributingKeyPairs = distributingClosedGroupEncryptionKeyPairs[groupPublicKey] ?? []
        distributingKeyPairs.append(newKeyPair)
        distributingClosedGroupEncryptionKeyPairs[groupPublicKey] = distributingKeyPairs
        let _ = MessageSender.sendNonDurably(closedGroupControlMessage, in: thread, using: transaction).done { // FIXME: It'd be great if we could make this a durable operation
            // Store it * after * having sent out the message to the group
            SNMessagingKitConfiguration.shared.storage.write { transaction in
                Storage.shared.addClosedGroupEncryptionKeyPair(newKeyPair, for: groupPublicKey, using: transaction)
            }
            var distributingKeyPairs = distributingClosedGroupEncryptionKeyPairs[groupPublicKey] ?? []
            if let index = distributingKeyPairs.firstIndex(of: newKeyPair) {
                distributingKeyPairs.remove(at: index)
            }
            distributingClosedGroupEncryptionKeyPairs[groupPublicKey] = distributingKeyPairs
        }
    }
    
    public static func update(_ groupPublicKey: String, with members: Set<String>, name: String, transaction: YapDatabaseReadWriteTransaction) throws {
        // Get the group, check preconditions & prepare
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let threadID = TSGroupThread.threadId(fromGroupId: groupID)
        guard let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
            SNLog("Can't update nonexistent closed group.")
            throw Error.noThread
        }
        let group = thread.groupModel
        // Update name if needed
        if name != group.groupName { try setName(to: name, for: groupPublicKey, using: transaction) }
        // Add members if needed
        let addedMembers = members.subtracting(group.groupMemberIds)
        if !addedMembers.isEmpty { try addMembers(addedMembers, to: groupPublicKey, using: transaction) }
        // Remove members if needed
        let removedMembers = Set(group.groupMemberIds).subtracting(members)
        if !removedMembers.isEmpty { try removeMembers(removedMembers, to: groupPublicKey, using: transaction) }
    }
    
    public static func setName(to name: String, for groupPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) throws {
        // Get the group, check preconditions & prepare
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let threadID = TSGroupThread.threadId(fromGroupId: groupID)
        guard let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
            SNLog("Can't change name for nonexistent closed group.")
            throw Error.noThread
        }
        guard !name.isEmpty else {
            SNLog("Can't set closed group name to an empty value.")
            throw Error.invalidClosedGroupUpdate
        }
        let group = thread.groupModel
        // Send the update to the group
        let closedGroupControlMessage = ClosedGroupControlMessage(kind: .nameChange(name: name))
        MessageSender.send(closedGroupControlMessage, in: thread, using: transaction)
        // Update the group
        let newGroupModel = TSGroupModel(title: name, memberIds: group.groupMemberIds, image: nil, groupId: groupID, groupType: .closedGroup, adminIds: group.groupAdminIds)
        thread.setGroupModel(newGroupModel, with: transaction)
        // Notify the user
        let updateInfo = group.getInfoStringAboutUpdate(to: newGroupModel)
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .groupUpdate, customMessage: updateInfo)
        infoMessage.save(with: transaction)
    }
    
    public static func addMembers(_ newMembers: Set<String>, to groupPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) throws {
        // Get the group, check preconditions & prepare
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let threadID = TSGroupThread.threadId(fromGroupId: groupID)
        guard let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
            SNLog("Can't add members to nonexistent closed group.")
            throw Error.noThread
        }
        guard !newMembers.isEmpty else {
            SNLog("Invalid closed group update.")
            throw Error.invalidClosedGroupUpdate
        }
        let group = thread.groupModel
        let members = [String](Set(group.groupMemberIds).union(newMembers))
        let membersAsData = members.map { Data(hex: $0) }
        let adminsAsData = group.groupAdminIds.map { Data(hex: $0) }
        guard let encryptionKeyPair = Storage.shared.getLatestClosedGroupEncryptionKeyPair(for: groupPublicKey) else {
            SNLog("Couldn't find encryption key pair for closed group: \(groupPublicKey).")
            throw Error.noKeyPair
        }
        // Send the update to the group
        let closedGroupControlMessage = ClosedGroupControlMessage(kind: .membersAdded(members: newMembers.map { Data(hex: $0) }))
        MessageSender.send(closedGroupControlMessage, in: thread, using: transaction)
        // Send updates to the new members individually
        for member in newMembers {
            let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
            thread.save(with: transaction)
            let closedGroupControlMessageKind = ClosedGroupControlMessage.Kind.new(publicKey: Data(hex: groupPublicKey), name: group.groupName!,
                encryptionKeyPair: encryptionKeyPair, members: membersAsData, admins: adminsAsData)
            let closedGroupControlMessage = ClosedGroupControlMessage(kind: closedGroupControlMessageKind)
            MessageSender.send(closedGroupControlMessage, in: thread, using: transaction)
        }
        // Update the group
        let newGroupModel = TSGroupModel(title: group.groupName, memberIds: members, image: nil, groupId: groupID, groupType: .closedGroup, adminIds: group.groupAdminIds)
        thread.setGroupModel(newGroupModel, with: transaction)
        // Notify the user
        let updateInfo = group.getInfoStringAboutUpdate(to: newGroupModel)
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .groupUpdate, customMessage: updateInfo)
        infoMessage.save(with: transaction)
    }
    
    public static func removeMembers(_ membersToRemove: Set<String>, to groupPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) throws {
        // Get the group, check preconditions & prepare
        let userPublicKey = getUserHexEncodedPublicKey()
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let threadID = TSGroupThread.threadId(fromGroupId: groupID)
        guard let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
            SNLog("Can't remove members from nonexistent closed group.")
            throw Error.noThread
        }
        guard !membersToRemove.isEmpty else {
            SNLog("Invalid closed group update.")
            throw Error.invalidClosedGroupUpdate
        }
        guard !membersToRemove.contains(userPublicKey) else {
            SNLog("Invalid closed group update.")
            throw Error.invalidClosedGroupUpdate
        }
        let group = thread.groupModel
        let members = Set(group.groupMemberIds).subtracting(membersToRemove)
        let isCurrentUserAdmin = group.groupAdminIds.contains(userPublicKey)
        // Send the update to the group and generate + distribute a new encryption key pair if needed
        let closedGroupControlMessage = ClosedGroupControlMessage(kind: .membersRemoved(members: membersToRemove.map { Data(hex: $0) }))
        if isCurrentUserAdmin {
            let _ = MessageSender.sendNonDurably(closedGroupControlMessage, in: thread, using: transaction).done {
                try generateAndSendNewEncryptionKeyPair(for: groupPublicKey, to: members, using: transaction)
            }
        } else {
            MessageSender.send(closedGroupControlMessage, in: thread, using: transaction)
        }
        // Update the group
        let newGroupModel = TSGroupModel(title: group.groupName, memberIds: [String](members), image: nil, groupId: groupID, groupType: .closedGroup, adminIds: group.groupAdminIds)
        thread.setGroupModel(newGroupModel, with: transaction)
        // Notify the user
        let updateInfo = group.getInfoStringAboutUpdate(to: newGroupModel)
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .groupUpdate, customMessage: updateInfo)
        infoMessage.save(with: transaction)
    }
    
    @objc(leaveClosedGroupWithPublicKey:using:error:)
    public static func leave(_ groupPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) throws {
        // Get the group, check preconditions & prepare
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let threadID = TSGroupThread.threadId(fromGroupId: groupID)
        guard let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
            SNLog("Can't leave nonexistent closed group.")
            throw Error.noThread
        }
        let group = thread.groupModel
        let userPublicKey = getUserHexEncodedPublicKey()
        let isCurrentUserAdmin = group.groupAdminIds.contains(userPublicKey)
        let members: Set<String> = isCurrentUserAdmin ? [] : Set(group.groupMemberIds).subtracting([ userPublicKey ]) // If the admin leaves the group is disbanded
        let admins: Set<String> = isCurrentUserAdmin ? [] : Set(group.groupAdminIds)
        // Send the update to the group
        let closedGroupControlMessage = ClosedGroupControlMessage(kind: .memberLeft)
        let _ = MessageSender.sendNonDurably(closedGroupControlMessage, in: thread, using: transaction).done {
            SNMessagingKitConfiguration.shared.storage.write { transaction in
                // Remove the group from the database and unsubscribe from PNs
                Storage.shared.removeAllClosedGroupEncryptionKeyPairs(for: groupPublicKey, using: transaction)
                Storage.shared.removeClosedGroupPublicKey(groupPublicKey, using: transaction)
                let _ = PushNotificationAPI.performOperation(.unsubscribe, for: groupPublicKey, publicKey: userPublicKey)
            }
        }
        // Update the group
        let newGroupModel = TSGroupModel(title: group.groupName, memberIds: [String](members), image: nil, groupId: groupID, groupType: .closedGroup, adminIds: [String](admins))
        thread.setGroupModel(newGroupModel, with: transaction)
        // Notify the user
        let updateInfo = group.getInfoStringAboutUpdate(to: newGroupModel)
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .groupUpdate, customMessage: updateInfo)
        infoMessage.save(with: transaction)
    }
    
    public static func requestEncryptionKeyPair(for groupPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) throws {
        #if DEBUG
        preconditionFailure("Shouldn't currently be in use.")
        #endif
        // Get the group, check preconditions & prepare
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let threadID = TSGroupThread.threadId(fromGroupId: groupID)
        guard let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
            SNLog("Can't request encryption key pair for nonexistent closed group.")
            throw Error.noThread
        }
        let group = thread.groupModel
        guard group.groupMemberIds.contains(getUserHexEncodedPublicKey()) else { return }
        // Send the request to the group
        let closedGroupControlMessage = ClosedGroupControlMessage(kind: .encryptionKeyPairRequest)
        MessageSender.send(closedGroupControlMessage, in: thread, using: transaction)
    }
    
    public static func sendLatestEncryptionKeyPair(to publicKey: String, for groupPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) {
        // Check that the user in question is part of the closed group
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let threadID = TSGroupThread.threadId(fromGroupId: groupID)
        guard let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
            return SNLog("Couldn't find thread .")
        }
        let group = thread.groupModel
        guard group.groupMemberIds.contains(publicKey) else {
            return SNLog("Refusing to send latest encryption key pair to non-member.")
        }
        // Get the latest encryption key pair
        guard let encryptionKeyPair = distributingClosedGroupEncryptionKeyPairs[groupPublicKey]?.last
            ?? Storage.shared.getLatestClosedGroupEncryptionKeyPair(for: groupPublicKey) else { return }
        // Send it
        guard let proto = try? SNProtoKeyPair.builder(publicKey: encryptionKeyPair.publicKey,
            privateKey: encryptionKeyPair.privateKey).build(), let plaintext = try? proto.serializedData() else { return }
        let contactThread = TSContactThread.getOrCreateThread(withContactId: publicKey, transaction: transaction)
        guard let ciphertext = try? MessageSender.encryptWithSessionProtocol(plaintext, for: publicKey) else { return }
        SNLog("Sending latest encryption key pair to: \(publicKey).")
        let wrapper = ClosedGroupControlMessage.KeyPairWrapper(publicKey: publicKey, encryptedKeyPair: ciphertext)
        let closedGroupControlMessage = ClosedGroupControlMessage(kind: .encryptionKeyPair(publicKey: Data(hex: groupPublicKey), wrappers: [ wrapper ]))
        MessageSender.send(closedGroupControlMessage, in: contactThread, using: transaction)
    }
}
