package core

import (
	"errors"
	"fmt"
)

// WrapError wraps given err with a message.
func WrapError(err error, msg string) *Error {
	return wrapError(err, msg)
}

// WrapErrorf wraps given err with a formatted message.
func WrapErrorf(err error, format string, a ...any) *Error {
	return wrapError(err, fmt.Sprintf(format, a...))
}

func wrapError(err error, msg string) *Error {
	var attr Attr
	var res *Error
	if e, ok := err.(*Error); ok {
		attr = ErrorNodeWrap(msg)
		res = e
	} else {
		attr = ErrorNodeWrapInherited(msg)
		if e, ok = errors.AsType[*Error](err); ok {
			res = &Error{
				payload: e.payload,
				wrap:    err,
			}
		} else {
			res = &Error{
				payload: make([]byte, 0, defaultPayloadSize),
				wrap:    err,
			}
		}
	}
	res.payload = AppendSerialized(res.payload, attr)

	if insertLocations {
		res.appendLocation(4)
	}
	return res
}
