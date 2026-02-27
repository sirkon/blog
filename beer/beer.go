package beer

import (
	"github.com/sirkon/blog/internal/core"
)

type Error = core.Error

func New(msg string) *Error {
	return core.NewError(msg)
}

func Newf(format string, a ...any) *Error {
	return core.NewErrorf(format, a...)
}

func Wrap(err error, msg string) *Error {
	return core.WrapError(err, msg)
}

func Wrapf(err error, format string, a ...any) *Error {
	return core.WrapErrorf(err, format, a...)
}

func Just(err error) *Error {
	return core.JustError(err)
}
