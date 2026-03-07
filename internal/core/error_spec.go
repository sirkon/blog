package core

import (
	"errors"
	"reflect"
)

// specNode adds a mark of given type to an error.
type specNode struct {
	spec any
	next *specNode
}

// Spec puts a tag on the error. These things are meant to be used
// for domain specific errors without bothering with special error types.
// Just put a [Spec] on an error, and you'll have enough info.
//
// A general idea is to use these [*Error] as domain specific errors
// too, with all this error context stuff and blazing fast logging.
func Spec(err error, spec any) *Error {
	if e, ok := err.(*Error); ok {
		e.specs = &specNode{
			spec: spec,
			next: e.specs,
		}
		return e
	}
	if e, ok := errors.AsType[*Error](err); ok {
		res := &Error{
			payload:    e.payload,
			wrap:       err,
			sufficient: false,
			specs:      &specNode{spec: spec},
		}
		wrapAttr := ErrorNodePhantomContext()
		res.payload = AppendSerialized(res.payload, wrapAttr)
		return res
	}

	res := &Error{
		payload:    make([]byte, 0, defaultPayloadSize),
		wrap:       err,
		sufficient: true,
		specs: &specNode{
			spec: spec,
		},
	}
	wrapAttr := ErrorNodeForeignErrorText(err.Error())
	res.payload = AppendSerialized(res.payload, wrapAttr)
	attr := ErrorNodePhantomContext()
	res.payload = AppendSerialized(res.payload, attr)

	return res
}

// AsSpec checks if an error was given a spec of certain type and
// returns the spec.
func AsSpec[T any](err error) (T, bool) {
	for {
		e, ok := err.(*Error)
		if !ok {
			e, ok = errors.AsType[*Error](err)
		}
		if !ok {
			var zero T
			return zero, false
		}

		spec := e.specs
		for spec != nil {
			if v, ok := spec.spec.(T); ok {
				return v, true
			}

			spec = spec.next
		}

		if e.wrap != nil {
			err = e.wrap
			continue
		}

		var zero T
		return zero, false
	}
}

func IsSpec[T any](err error) bool {
	target := reflect.TypeFor[T]()

	for {
		e, ok := err.(*Error)
		if !ok {
			e, ok = errors.AsType[*Error](err)
		}
		if !ok {
			return false
		}

		for spec := e.specs; spec != nil; spec = spec.next {
			if reflect.TypeOf(spec.spec) == target {
				return true
			}
		}

		if e.wrap != nil {
			err = e.wrap
			continue
		}

		return false
	}
}
