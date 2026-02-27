package core

import (
	"encoding/binary"
	"errors"
	"strings"
)

const defaultPayloadSize = 512

// Error implements error interface and provides structured context for [blog.Logger].
type Error struct {
	payload []byte
	wrap    error
	text    string
}

func (e *Error) Error() string {
	nodes := make([][]byte, 0, 8)
	var strInsert string

	payload := e.payload
	if e.wrap != nil {
		if err, ok := errors.AsType[*Error](e.wrap); ok {
			// We should pass the part of context of wrapped Error because
			// we'll see its text via the call to wrapped error.
			payload = payload[len(err.payload):]
		}
	}

	for len(payload) > 0 {
		kind := ValueKind(payload[0])
		payload = payload[1:]
		switch kind {
		case ValueKindJustContextNode:
			continue
		case ValueKindJustContextInheritedNode:
			nodes = append(nodes, nil)
			strInsert = e.wrap.Error()
			continue
		}

		var key []byte
		length, varintLength := binary.Uvarint(payload)
		if length > 0 {
			key = payload[varintLength : varintLength+int(length)]
		}
		payload = payload[varintLength+int(length):]
		switch kind {
		case ValueKindNewNode, ValueKindWrapNode:
			nodes = append(nodes, key)

		case ValueKindWrapInheritedNode:
			nodes = append(nodes, nil)
			strInsert = e.wrap.Error()
			nodes = append(nodes, key)

		case ValueKindLocationNode:
			_, varintLength = binary.Uvarint(payload)
			payload = payload[varintLength:]

		case ValueKindBool, ValueKindInt8, ValueKindUint8:
			payload = payload[1:]
		case ValueKindInt16, ValueKindUint16:
			payload = payload[2:]
		case ValueKindInt32, ValueKindUint32, ValueKindFloat32:
			payload = payload[4:]
		case ValueKindTime, ValueKindDuration,
			ValueKindInt, ValueKindInt64,
			ValueKindUint, ValueKindUint64,
			ValueKindFloat64:
			payload = payload[8:]
		case ValueKindString, ValueKindBytes, ValueKindSerializer:
			length, varintLength = binary.Uvarint(payload)
			payload = payload[varintLength+int(length):]
		case ValueKindSliceBool, ValueKindSliceInt8, ValueKindSliceUint8:
			length, varintLength = binary.Uvarint(payload)
			payload = payload[varintLength+int(length):]
		case ValueKindSliceInt16, ValueKindSliceUint16:
			payload = payload[varintLength+2*int(length):]
		case ValueKindSliceInt32, ValueKindSliceUint32, ValueKindSliceFloat32:
			payload = payload[varintLength+4*int(length):]
		case ValueKindSliceInt, ValueKindSliceInt64,
			ValueKindSliceUint, ValueKindSliceUint64,
			ValueKindSliceFloat64:
			payload = payload[varintLength+8*int(length):]
		case ValueKindSliceString:
			length, varintLength = binary.Uvarint(payload)
			payload = payload[varintLength:]
			for range length {
				l, vl := binary.Uvarint(payload)
				payload = payload[vl+int(l):]
			}
		case ValueKindGroup:
			// JustError need to pass the length of group. The group itself
			// is just a regular sequence of attributes, this loop will deal with it itself.
			_, varintLength = binary.Uvarint(payload)
			payload = payload[varintLength:]
		}
	}

	var builder strings.Builder
	for i := len(nodes) - 1; i >= 0; i-- {
		node := nodes[i]
		if node == nil {
			builder.WriteString(strInsert)
		} else {
			builder.Write(node)
		}
		if i > 0 {
			builder.WriteString(": ")
		}
	}

	return builder.String()
}
