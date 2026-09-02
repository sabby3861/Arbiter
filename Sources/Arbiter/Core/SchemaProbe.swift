// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A `Decoder` that answers every request with a placeholder and records what was asked
/// for, so a `Decodable` type describes its own shape by decoding itself.
///
/// Only the JSON shape matters, so the placeholders match what `JSONDecoder` would need:
/// `Date` reads a number (its default strategy is `deferredToDate`), `Data` a base64
/// string, `URL` and `UUID` strings.
enum SchemaProbe {
    /// Record `type`'s shape into `node`, returning the placeholder value it decoded to.
    static func value<T: Decodable>(
        of type: T.Type,
        into node: SchemaNode,
        state: ProbeState,
        codingPath: [CodingKey]
    ) throws -> T {
        if let scalar = scalarPlaceholder(for: type) {
            node.kind = scalar.kind
            return try cast(scalar.value, to: type)
        }
        try state.enter(type)
        defer { state.leave() }
        let decoder = SchemaProbeDecoder(node: node, state: state, codingPath: codingPath)
        return try T(from: decoder)
    }

    private static func scalarPlaceholder<T>(for type: T.Type) -> (kind: SchemaNode.Kind, value: Any)? {
        switch ObjectIdentifier(type) {
        case ObjectIdentifier(String.self): (.string, "")
        case ObjectIdentifier(URL.self): (.string, URL(fileURLWithPath: "/"))
        case ObjectIdentifier(UUID.self): (.string, UUID())
        // `JSONDecoder` reads `Data` as base64 text and `Date` as a number by default,
        // whatever the two types' own `init(from:)` would do with a real container.
        case ObjectIdentifier(Data.self): (.string, Data())
        case ObjectIdentifier(Date.self): (.number, Date(timeIntervalSinceReferenceDate: 0))
        case ObjectIdentifier(Bool.self): (.boolean, false)
        case ObjectIdentifier(Double.self): (.number, Double(0))
        case ObjectIdentifier(Float.self): (.number, Float(0))
        case ObjectIdentifier(Decimal.self): (.number, Decimal(0))
        case ObjectIdentifier(Int.self): (.integer, Int(0))
        case ObjectIdentifier(Int8.self): (.integer, Int8(0))
        case ObjectIdentifier(Int16.self): (.integer, Int16(0))
        case ObjectIdentifier(Int32.self): (.integer, Int32(0))
        case ObjectIdentifier(Int64.self): (.integer, Int64(0))
        case ObjectIdentifier(UInt.self): (.integer, UInt(0))
        case ObjectIdentifier(UInt8.self): (.integer, UInt8(0))
        case ObjectIdentifier(UInt16.self): (.integer, UInt16(0))
        case ObjectIdentifier(UInt32.self): (.integer, UInt32(0))
        case ObjectIdentifier(UInt64.self): (.integer, UInt64(0))
        default: nil
        }
    }

    private static func cast<T>(_ value: Any, to type: T.Type) throws -> T {
        guard let typed = value as? T else {
            throw SchemaProbeError.unsupported("no placeholder value for \(type)")
        }
        return typed
    }
}

struct SchemaProbeDecoder: Decoder {
    let node: SchemaNode
    let state: ProbeState
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        node.kind = .object
        return KeyedDecodingContainer(
            SchemaProbeKeyedContainer<Key>(node: node, state: state, codingPath: codingPath)
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        node.kind = .array
        return SchemaProbeUnkeyedContainer(node: node, state: state, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        SchemaProbeSingleValueContainer(node: node, state: state, codingPath: codingPath)
    }
}

private struct SchemaProbeKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let node: SchemaNode
    let state: ProbeState
    var codingPath: [CodingKey]

    /// Empty, and recorded: only a type with dynamic keys — a dictionary, or a decoder
    /// branching on what it finds — asks, and the shape it would infer from an empty answer
    /// is not the shape it really has. ``SchemaNode`` refuses to emit a node that asked.
    var allKeys: [Key] {
        node.sawDynamicKeys = true
        return []
    }

    /// Every key the type asks about is treated as present, so a decoder that branches on
    /// `contains` takes its main path rather than its absent-value path.
    func contains(_ key: Key) -> Bool { true }

    /// Never nil: a null placeholder would tell an optional property nothing about its type.
    func decodeNil(forKey key: Key) throws -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try probe(type, forKey: key, required: true)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try probe(type, forKey: key, required: false)
    }

    private func probe<T: Decodable>(_ type: T.Type, forKey key: Key, required: Bool) throws -> T {
        try SchemaProbe.value(
            of: type,
            into: node.property(key.stringValue, required: required),
            state: state,
            codingPath: codingPath + [key]
        )
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try probe(type, forKey: key, required: true) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try probe(type, forKey: key, required: true) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try probe(type, forKey: key, required: true) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try probe(type, forKey: key, required: true) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try probe(type, forKey: key, required: true) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try probe(type, forKey: key, required: true) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try probe(type, forKey: key, required: true) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try probe(type, forKey: key, required: true) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try probe(type, forKey: key, required: true) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try probe(type, forKey: key, required: true) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try probe(type, forKey: key, required: true) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try probe(type, forKey: key, required: true) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try probe(type, forKey: key, required: true) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try probe(type, forKey: key, required: true) }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try probe(type, forKey: key, required: false) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try probe(type, forKey: key, required: false) }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let child = node.property(key.stringValue, required: true)
        child.kind = .object
        return KeyedDecodingContainer(
            SchemaProbeKeyedContainer<NestedKey>(
                node: child, state: state, codingPath: codingPath + [key]
            )
        )
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let child = node.property(key.stringValue, required: true)
        child.kind = .array
        return SchemaProbeUnkeyedContainer(
            node: child, state: state, codingPath: codingPath + [key]
        )
    }

    func superDecoder() throws -> Decoder {
        SchemaProbeDecoder(node: node, state: state, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        SchemaProbeDecoder(
            node: node.property(key.stringValue, required: true),
            state: state,
            codingPath: codingPath + [key]
        )
    }
}

private struct SchemaProbeUnkeyedContainer: UnkeyedDecodingContainer {
    let node: SchemaNode
    let state: ProbeState
    var codingPath: [CodingKey]
    /// One element: enough to learn the element type, and the end of the loop an array's
    /// `init(from:)` runs.
    var count: Int? { 1 }
    var currentIndex: Int = 0
    var isAtEnd: Bool { currentIndex >= 1 }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        currentIndex += 1
        return try SchemaProbe.value(
            of: type, into: node.element(), state: state, codingPath: codingPath
        )
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try decodeElement(type) }
    mutating func decode(_ type: String.Type) throws -> String { try decodeElement(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try decodeElement(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try decodeElement(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try decodeElement(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try decodeElement(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try decodeElement(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try decodeElement(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try decodeElement(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try decodeElement(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeElement(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeElement(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeElement(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeElement(type) }

    private mutating func decodeElement<T: Decodable>(_ type: T.Type) throws -> T {
        currentIndex += 1
        return try SchemaProbe.value(
            of: type, into: node.element(), state: state, codingPath: codingPath
        )
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        currentIndex += 1
        let element = node.element()
        element.kind = .object
        return KeyedDecodingContainer(
            SchemaProbeKeyedContainer<NestedKey>(node: element, state: state, codingPath: codingPath)
        )
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        currentIndex += 1
        let element = node.element()
        element.kind = .array
        return SchemaProbeUnkeyedContainer(node: element, state: state, codingPath: codingPath)
    }

    mutating func superDecoder() throws -> Decoder {
        SchemaProbeDecoder(node: node.element(), state: state, codingPath: codingPath)
    }
}

private struct SchemaProbeSingleValueContainer: SingleValueDecodingContainer {
    let node: SchemaNode
    let state: ProbeState
    var codingPath: [CodingKey]

    func decodeNil() -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try SchemaProbe.value(of: type, into: node, state: state, codingPath: codingPath)
    }

    func decode(_ type: Bool.Type) throws -> Bool { try probe(type) }
    func decode(_ type: String.Type) throws -> String { try probe(type) }
    func decode(_ type: Double.Type) throws -> Double { try probe(type) }
    func decode(_ type: Float.Type) throws -> Float { try probe(type) }
    func decode(_ type: Int.Type) throws -> Int { try probe(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try probe(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try probe(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try probe(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try probe(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try probe(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try probe(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try probe(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try probe(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try probe(type) }

    private func probe<T: Decodable>(_ type: T.Type) throws -> T {
        try SchemaProbe.value(of: type, into: node, state: state, codingPath: codingPath)
    }
}
