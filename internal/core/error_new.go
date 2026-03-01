package core

import (
	"fmt"
)

// NewError creates new error with the given text. Must not be used for sentinel errors.
func NewError(msg string) *Error {
	return newError(msg)
}

// NewErrorf creates new error with the format.
func NewErrorf(format string, a ...any) *Error {
	return newError(fmt.Sprintf(format, a...))
}

func newError(msg string) *Error {
	payload := make([]byte, 0, defaultPayloadSize)

	attr := ErrorNodeNew(msg)
	payload = AppendSerialized(payload, attr)

	res := &Error{
		payload:    payload,
		wrap:       nil,
		sufficient: true,
	}

	if insertLocations {
		res.appendLocation(4)
	}

	return res
}
