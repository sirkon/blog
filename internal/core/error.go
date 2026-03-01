package core

import (
	"encoding/binary"
	"errors"
	"strings"
)

const defaultPayloadSize = 512

// Error implements error interface and provides structured context for [blog.Logger].
type Error struct {
	payload    []byte
	wrap       error
	text       string
	sufficient bool
}

func (e *Error) Error() string {
	nodes := make([][]byte, 0, 8)
	var strInsert string

	payload := e.payload
	if e.wrap != nil && !e.sufficient {
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
			if !e.sufficient {
				nodes = append(nodes, nil)
				strInsert = e.wrap.Error()
			}
			break
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
			if !e.sufficient {
				nodes = append(nodes, nil)
				strInsert = e.wrap.Error()
				nodes = append(nodes, key)
			} else {
				nodes = append(nodes, key)
			}
		case ValueKindForeignErrorText:
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

var colsep = []byte{':', ' '}

func SufficientErrorBytes(payload []byte) []byte {
	nodes := make([][]byte, 0, 8)

	var totalLen int
	for len(payload) > 0 {
		kind := ValueKind(payload[0])
		payload = payload[1:]
		switch kind {
		case ValueKindJustContextNode:
			continue
		case ValueKindJustContextInheritedNode:
			break
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
			totalLen += len(key)

		case ValueKindWrapInheritedNode:
			nodes = append(nodes, key)
			totalLen += len(key)

		case ValueKindForeignErrorText:
			nodes = append(nodes, key)
			totalLen += len(key)

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

	data := make([]byte, 0, totalLen+2*(len(nodes)-1))
	for i := len(nodes) - 1; i >= 0; i-- {
		node := nodes[i]
		data = append(data, node...)
		data = append(data, colsep...)
	}

	return data
}

// Unwrap for std errors.
func (e *Error) Unwrap() error {
	return e.wrap
}

// As for [errors.As]
func (e *Error) As(target any) bool {
	v, ok := target.(**Error)
	if ok {
		*v = e
		return true
	}

	if e.wrap == nil {
		return false
	}

	return errors.As(e.wrap, target)
}

// Is for [errors.Is]. We only return false for *[Error] target.
func (e *Error) Is(target error) bool {
	if _, ok := target.(*Error); ok {
		return false
	}

	if e.wrap == nil {
		return false
	}

	return errors.Is(e.wrap, target)
}
