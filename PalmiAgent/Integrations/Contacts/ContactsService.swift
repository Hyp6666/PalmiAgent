import Contacts
import Foundation

enum ContactSearchScope: String {
    case name
    case phone
    case email
    case organization
    case note
    case address
    case url
    case all
}

struct LabeledContactValue {
    let label: String?
    let value: String
}

struct ContactPostalAddressInput {
    let label: String?
    let street: String
    let city: String?
    let state: String?
    let postalCode: String?
    let country: String?
    let isoCountryCode: String?
}

@MainActor
final class ContactsService {
    private let store = CNContactStore()

    func createSampleContact() async throws -> String {
        try await createContact(
            givenName: "小助理",
            familyName: "测试",
            organizationName: "PalmiAgent",
            phoneNumbers: ["10086"],
            emailAddresses: ["palmi@example.com"],
            note: "由 PalmiAgent 创建。"
        )
    }

    func createContact(
        givenName: String,
        familyName: String,
        organizationName: String?,
        phoneNumbers: [String],
        emailAddresses: [String],
        note: String?,
        middleName: String? = nil,
        nickname: String? = nil,
        jobTitle: String? = nil,
        departmentName: String? = nil,
        labeledPhoneNumbers: [LabeledContactValue] = [],
        labeledEmailAddresses: [LabeledContactValue] = [],
        labeledURLAddresses: [LabeledContactValue] = [],
        postalAddresses: [ContactPostalAddressInput] = [],
        birthday: Date? = nil
    ) async throws -> String {
        let granted = try await requestAccess()
        guard granted else {
            throw AppError.permissionDenied("通讯录权限没有授予。")
        }

        let contact = CNMutableContact()
        contact.familyName = familyName
        contact.givenName = givenName
        contact.middleName = middleName ?? ""
        contact.nickname = nickname ?? ""
        contact.organizationName = organizationName ?? ""
        contact.jobTitle = jobTitle ?? ""
        contact.departmentName = departmentName ?? ""
        contact.phoneNumbers = (phoneNumbers.map {
            LabeledContactValue(label: CNLabelPhoneNumberMobile, value: $0)
        } + labeledPhoneNumbers).map {
            CNLabeledValue(label: normalizedLabel($0.label, fallback: CNLabelPhoneNumberMobile), value: CNPhoneNumber(stringValue: $0.value))
        }
        contact.emailAddresses = (emailAddresses.map {
            LabeledContactValue(label: CNLabelWork, value: $0)
        } + labeledEmailAddresses).map {
            CNLabeledValue(label: normalizedLabel($0.label, fallback: CNLabelWork), value: $0.value as NSString)
        }
        contact.urlAddresses = labeledURLAddresses.map {
            CNLabeledValue(label: normalizedLabel($0.label, fallback: CNLabelURLAddressHomePage), value: $0.value as NSString)
        }
        contact.postalAddresses = postalAddresses.map { address in
            let postalAddress = CNMutablePostalAddress()
            postalAddress.street = address.street
            postalAddress.city = address.city ?? ""
            postalAddress.state = address.state ?? ""
            postalAddress.postalCode = address.postalCode ?? ""
            postalAddress.country = address.country ?? ""
            postalAddress.isoCountryCode = address.isoCountryCode ?? ""
            return CNLabeledValue(
                label: normalizedLabel(address.label, fallback: CNLabelHome),
                value: postalAddress.copy() as! CNPostalAddress
            )
        }
        if let birthday {
            contact.birthday = Calendar.current.dateComponents([.year, .month, .day], from: birthday)
        }
        contact.note = note ?? ""

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try store.execute(request)
        return CNContactFormatter.string(from: contact, style: .fullName) ?? "测试小助理"
    }

    func searchContacts(
        keyword: String = "Palmi",
        scope: ContactSearchScope = .all
    ) async throws -> [CNContact] {
        let granted = try await requestAccess()
        guard granted else {
            throw AppError.permissionDenied("通讯录权限没有授予。")
        }

        let keys = contactKeysToFetch()
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let contacts = try fetchAllContacts(keys: keys)
        guard !trimmedKeyword.isEmpty else {
            return contacts
        }

        return contacts.filter { contact in
            matches(contact, keyword: trimmedKeyword, scope: scope)
        }
    }

    private func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func contactKeysToFetch() -> [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactNoteKey as CNKeyDescriptor
        ]
    }

    private func fetchAllContacts(keys: [CNKeyDescriptor]) throws -> [CNContact] {
        var contacts: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    private func matches(
        _ contact: CNContact,
        keyword: String,
        scope: ContactSearchScope
    ) -> Bool {
        let normalizedKeyword = keyword.lowercased()
        let name = CNContactFormatter.string(from: contact, style: .fullName)?.lowercased() ?? ""

        let fields: [String]
        switch scope {
        case .name:
            fields = [name, contact.nickname.lowercased()]
        case .phone:
            fields = contact.phoneNumbers.map { $0.value.stringValue.lowercased() }
        case .email:
            fields = contact.emailAddresses.map { ($0.value as String).lowercased() }
        case .organization:
            fields = [contact.organizationName.lowercased(), contact.departmentName.lowercased(), contact.jobTitle.lowercased()]
        case .note:
            fields = [contact.note.lowercased()]
        case .address:
            fields = contact.postalAddresses.map { value in
                let address = value.value
                return [address.street, address.city, address.state, address.postalCode, address.country]
                    .joined(separator: " ")
                    .lowercased()
            }
        case .url:
            fields = contact.urlAddresses.map { ($0.value as String).lowercased() }
        case .all:
            fields = [
                name,
                contact.nickname.lowercased(),
                contact.organizationName.lowercased(),
                contact.departmentName.lowercased(),
                contact.jobTitle.lowercased(),
                contact.note.lowercased()
            ]
            + contact.phoneNumbers.map { $0.value.stringValue.lowercased() }
            + contact.emailAddresses.map { ($0.value as String).lowercased() }
            + contact.urlAddresses.map { ($0.value as String).lowercased() }
            + contact.postalAddresses.map { value in
                let address = value.value
                return [address.street, address.city, address.state, address.postalCode, address.country]
                    .joined(separator: " ")
                    .lowercased()
            }
        }

        return fields.contains { $0.localizedCaseInsensitiveContains(normalizedKeyword) }
    }

    private func normalizedLabel(_ label: String?, fallback: String) -> String {
        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalized {
        case "", "default":
            return fallback
        case "home":
            return CNLabelHome
        case "work":
            return CNLabelWork
        case "other":
            return CNLabelOther
        case "mobile":
            return CNLabelPhoneNumberMobile
        case "main":
            return CNLabelPhoneNumberMain
        case "iphone":
            return CNLabelPhoneNumberiPhone
        default:
            return label ?? fallback
        }
    }
}
