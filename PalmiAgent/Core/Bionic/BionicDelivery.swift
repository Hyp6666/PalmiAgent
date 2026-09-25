import Foundation

nonisolated enum BionicDelivery {
    static let contract = "prepared_reply_delivery"

    static func isReply(_ group: BionicObject) -> Bool {
        BionicDeliveryPolicy.isReply(group)
    }

    static func pending(_ group: BionicObject, in role: BionicRole) -> Bool {
        group.records("items").contains {
            role.state.itemState($0.text("message_id")) == "pending"
        }
    }
}
