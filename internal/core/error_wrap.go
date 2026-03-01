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
			// We have our error wrapped via a foreign function.
			// We can't rely on the payload to render the full error text from now on.
			// Reflect this fact in the sufficient field.
			res = &Error{
				payload:    e.payload,
				wrap:       err,
				sufficient: false,
			}
		} else {
			// We got an error that is totally outside of ours and we can just push it into a payload
			// without hesitation.
			res = &Error{
				payload:    make([]byte, 0, defaultPayloadSize),
				wrap:       err,
				sufficient: true,
			}
			wrapAttr := ErrorNodeForeignErrorText(err.Error())
			res.payload = AppendSerialized(res.payload, wrapAttr)
		}
	}
	res.payload = AppendSerialized(res.payload, attr)

	if insertLocations {
		res.appendLocation(4)
	}
	return res
}
