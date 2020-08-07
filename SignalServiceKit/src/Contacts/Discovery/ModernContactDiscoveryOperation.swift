//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

struct CDSRegisteredContact: Hashable {
    let signalUuid: UUID
    let e164PhoneNumber: String
}

/// Fetches contact info from the ContactDiscoveryService
/// Intended to be used by ContactDiscoveryTask. You probably don't want to use this directly.
class ModernContactDiscoveryOperation: ContactDiscovering {
    static let batchSize = 2048

    private let phoneNumbersToLookup: Set<String>
    required init(phoneNumbersToLookup: Set<String>) {
        self.phoneNumbersToLookup = phoneNumbersToLookup
        Logger.debug("with phoneNumbersToLookup.count: \(phoneNumbersToLookup.count)")
    }

    func perform(on queue: DispatchQueue) -> Promise<Set<DiscoveredContactInfo>> {
        firstly { () -> Promise<[Set<CDSRegisteredContact>]> in
            // First, build a bunch of batch Promises
            let batchOperationPromises = Array(phoneNumbersToLookup)
                .chunked(by: Self.batchSize)
                .map { makeContactDiscoveryRequest(phoneNumbersToLookup: $0) }

            // Then, wait for them all to be fulfilled before joining the subsets together
            return when(fulfilled: batchOperationPromises)

        }.map(on: queue) { (setArray) -> Set<DiscoveredContactInfo> in
            setArray.reduce(into: Set()) { (builder, cdsContactSubset) in
                builder.formUnion(cdsContactSubset.map {
                    DiscoveredContactInfo(e164: $0.e164PhoneNumber, uuid: $0.signalUuid)
                })
            }
        }
    }

    // Below, we have a bunch of then blocks being performed on a global concurrent queue
    // It might be worthwhile to audit and see if we can move these onto the queue passed into `perform(on:)`

    private func makeContactDiscoveryRequest(phoneNumbersToLookup: [String]) -> Promise<Set<CDSRegisteredContact>> {
        let contactCount = UInt(phoneNumbersToLookup.count)

        return firstly { () -> Promise<RemoteAttestation.CDSAttestation> in
            RemoteAttestation.performForCDS()
        }.then(on: .global()) { (attestation: RemoteAttestation.CDSAttestation) -> Promise<Set<CDSRegisteredContact>> in
            return firstly { () -> Promise<ContactDiscoveryService.IntersectionResponse> in
                let query = try self.buildIntersectionQuery(phoneNumbersToLookup: phoneNumbersToLookup,
                                                            remoteAttestations: attestation.remoteAttestations)
                return ContactDiscoveryService().getRegisteredSignalUsers(query: query,
                                                                          cookies: attestation.cookies,
                                                                          authUsername: attestation.auth.username,
                                                                          authPassword: attestation.auth.password,
                                                                          enclaveName: attestation.enclaveConfig.enclaveName,
                                                                          host: attestation.enclaveConfig.host,
                                                                          censorshipCircumventionPrefix: attestation.enclaveConfig.censorshipCircumventionPrefix)
            }.map(on: .global()) { response -> Set<CDSRegisteredContact> in
                let allEnclaveAttestations = attestation.remoteAttestations
                let respondingEnclaveAttestation = allEnclaveAttestations.first(where: { $1.requestId == response.requestId })
                guard let responseAttestion = respondingEnclaveAttestation?.value else {
                    throw OWSAssertionError("unable to find responseAttestation for requestId: \(response.requestId)")
                }

                guard let plaintext = Cryptography.decryptAESGCM(withInitializationVector: response.iv,
                                                                 ciphertext: response.data,
                                                                 additionalAuthenticatedData: nil,
                                                                 authTag: response.mac,
                                                                 key: responseAttestion.keys.serverKey) else {
                                                                    throw ContactDiscoveryError.parseError(description: "decryption failed")
                }

                // 16 bytes per UUID
                assert(plaintext.count == contactCount * 16)
                let dataParser = OWSDataParser(data: plaintext)
                let uuidsData = try dataParser.nextData(length: contactCount * 16, name: "uuids")

                guard dataParser.isEmpty else {
                    throw OWSAssertionError("failed check: dataParse.isEmpty")
                }

                let uuids = type(of: self).uuidArray(from: uuidsData)

                guard uuids.count == contactCount else {
                    throw OWSAssertionError("failed check: uuids.count == contactCount")
                }

                let unregisteredUuid = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

                var registeredContacts: Set<CDSRegisteredContact> = Set()

                for (index, e164PhoneNumber) in phoneNumbersToLookup.enumerated() {
                    guard uuids[index] != unregisteredUuid else {
                        Logger.verbose("not a signal user: \(e164PhoneNumber)")
                        continue
                    }

                    Logger.verbose("signal user: \(e164PhoneNumber)")
                    registeredContacts.insert(CDSRegisteredContact(signalUuid: uuids[index],
                                                                   e164PhoneNumber: e164PhoneNumber))
                }

                return registeredContacts
            }
        }
    }

    func buildIntersectionQuery(phoneNumbersToLookup: [String], remoteAttestations: [RemoteAttestation.CDSAttestation.Id: RemoteAttestation]) throws -> ContactDiscoveryService.IntersectionQuery {
        let noncePlainTextData = Randomness.generateRandomBytes(32)
        let addressPlainTextData = try type(of: self).encodePhoneNumbers(phoneNumbersToLookup)
        let queryData = Data.join([noncePlainTextData, addressPlainTextData])

        let key = OWSAES256Key.generateRandom()
        guard let encryptionResult = Cryptography.encryptAESGCM(plainTextData: queryData,
                                                                initializationVectorLength: kAESGCM256_DefaultIVLength,
                                                                additionalAuthenticatedData: nil,
                                                                key: key) else {
                                                                    throw ContactDiscoveryError.assertionError(description: "Encryption failure")
        }
        assert(encryptionResult.ciphertext.count == phoneNumbersToLookup.count * 8 + 32)

        let queryEnvelopes: [RemoteAttestation.CDSAttestation.Id: ContactDiscoveryService.IntersectionQuery.EnclaveEnvelope] = try remoteAttestations.mapValues { remoteAttestation in
            guard let perEnclaveKey = Cryptography.encryptAESGCM(plainTextData: key.keyData,
                                                                 initializationVectorLength: kAESGCM256_DefaultIVLength,
                                                                 additionalAuthenticatedData: remoteAttestation.requestId,
                                                                 key: remoteAttestation.keys.clientKey) else {
                                                                    throw OWSAssertionError("failed to encrypt perEnclaveKey")
            }

            return ContactDiscoveryService.IntersectionQuery.EnclaveEnvelope(requestId: remoteAttestation.requestId,
                                                                             data: perEnclaveKey.ciphertext,
                                                                             iv: perEnclaveKey.initializationVector,
                                                                             mac: perEnclaveKey.authTag)
        }

        guard let commitment = Cryptography.computeSHA256Digest(queryData) else {
            throw OWSAssertionError("commitment was unexpectedly nil")
        }

        return ContactDiscoveryService.IntersectionQuery(addressCount: UInt(phoneNumbersToLookup.count),
                                                         commitment: commitment,
                                                         data: encryptionResult.ciphertext,
                                                         iv: encryptionResult.initializationVector,
                                                         mac: encryptionResult.authTag,
                                                         envelopes: queryEnvelopes)
    }

    class func encodePhoneNumbers(_ phoneNumbers: [String]) throws -> Data {
        var output = Data()

        for phoneNumber in phoneNumbers {
            guard phoneNumber.prefix(1) == "+" else {
                throw ContactDiscoveryError.assertionError(description: "unexpected id format")
            }

            let numericPortionIndex = phoneNumber.index(after: phoneNumber.startIndex)
            let numericPortion = phoneNumber.suffix(from: numericPortionIndex)

            guard let numericIdentifier = UInt64(numericPortion), numericIdentifier > 99 else {
                throw ContactDiscoveryError.assertionError(description: "unexpectedly short identifier")
            }

            var bigEndian: UInt64 = CFSwapInt64HostToBig(numericIdentifier)
            withUnsafePointer(to: &bigEndian) { pointer in
                output.append(UnsafeBufferPointer(start: pointer, count: 1))
            }
        }

        return output
    }

    class func uuidArray(from data: Data) -> [UUID] {
        return data.withUnsafeBytes {
            [uuid_t]($0.bindMemory(to: uuid_t.self))
        }.map {
            UUID(uuid: $0)
        }
    }
}