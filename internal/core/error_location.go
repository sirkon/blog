package core

import (
	"runtime"
)

var insertLocations bool

// InsertLocationsOn enables location retrieval in [NewError]/[NewErrorf], [WrapError]/[WrapErrorf] and [JustError] calls.
// It is disabled by default. And better not to be enabled in production environments.
func InsertLocationsOn() {
	insertLocations = true
}

// InsertLocationsOff disables location retrieval in [NewError]/[NewErrorf], [WrapError]/[WrapErrorf] and [JustError] calls.
func InsertLocationsOff() {
	insertLocations = false
}

func (e *Error) appendLocation(skip int) {
	_, fn, line, ok := runtime.Caller(skip)
	if !ok {
		return
	}

	attr := ErrorNodeLocation(fn, line)
	e.payload = AppendSerialized(e.payload, attr)
}
