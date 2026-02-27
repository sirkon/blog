package core

import (
	"errors"
)

func JustError(err error) *Error {
	var attr Attr
	var res *Error
	if e, ok := err.(*Error); ok {
		attr = ErrorNodeJustContext()
		res = e
	} else {
		attr = ErrorNodeJustContextInherited()
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
		res.appendLocation(3)
	}
	return res
}
